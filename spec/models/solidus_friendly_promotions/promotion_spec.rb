# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusFriendlyPromotions::Promotion, type: :model do
  let(:promotion) { described_class.new }

  it { is_expected.to belong_to(:category).optional }
  it { is_expected.to respond_to(:customer_label) }
  it { is_expected.to have_many :rules }
  it { is_expected.to have_many(:order_promotions).dependent(:destroy) }

  describe "lane" do
    it { is_expected.to respond_to(:lane) }

    it "is default be default" do
      expect(subject.lane).to eq("default")
    end
  end

  describe "#destroy" do
    let!(:promotion) { create(:friendly_promotion, :with_adjustable_action) }

    subject { promotion.destroy! }

    it "destroys the promotion and nullifies the action" do
      expect { subject }.to change { SolidusFriendlyPromotions::Promotion.count }.by(-1)
      expect(SolidusFriendlyPromotions::PromotionAction.count).to eq(1)
      expect(SolidusFriendlyPromotions::PromotionAction.first.promotion_id).to be nil
    end
  end

  describe ".ordered_lanes" do
    subject { described_class.ordered_lanes }

    it { is_expected.to eq({"pre" => 0, "default" => 1, "post" => 2}) }
  end

  describe "validations" do
    subject(:promotion) { build(:friendly_promotion) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:customer_label) }
    it { is_expected.to validate_numericality_of(:usage_limit).is_greater_than(0) }
  end

  describe ".advertised" do
    let(:promotion) { create(:friendly_promotion) }
    let(:advertised_promotion) { create(:friendly_promotion, advertise: true) }

    it "only shows advertised promotions" do
      advertised = described_class.advertised
      expect(advertised).to include(advertised_promotion)
      expect(advertised).not_to include(promotion)
    end
  end

  describe ".coupons" do
    subject { described_class.coupons }

    let(:promotion_code) { create(:friendly_promotion_code) }
    let!(:promotion_with_code) { promotion_code.promotion }
    let!(:another_promotion_code) { create(:friendly_promotion_code, promotion: promotion_with_code) }
    let!(:promotion_without_code) { create(:friendly_promotion) }

    it "returns only distinct promotions with a code associated" do
      expect(subject).to eq [promotion_with_code]
    end
  end

  describe ".active" do
    subject { described_class.active }

    let(:promotion) { create(:friendly_promotion, starts_at: Date.yesterday, name: "name1") }

    before { promotion }

    it "doesn't return promotion without actions" do
      expect(subject).to be_empty
    end

    context "when promotion has an action" do
      let(:promotion) { create(:friendly_promotion, :with_adjustable_action, starts_at: Date.yesterday, name: "name1") }

      it "returns promotion with action" do
        expect(subject).to match [promotion]
      end
    end

    context "when called with a time that is not current" do
      subject { described_class.active(4.days.ago) }

      let(:promotion) do
        create(
          :friendly_promotion,
          :with_adjustable_action,
          starts_at: 5.days.ago,
          expires_at: 3.days.ago,
          name: "name1"
        )
      end

      it "returns promotion that was active then" do
        expect(subject).to match [promotion]
      end
    end
  end

  describe ".has_actions" do
    subject { described_class.has_actions }

    let(:promotion) { create(:friendly_promotion, starts_at: Date.yesterday, name: "name1") }

    before { promotion }

    it "doesn't return promotion without actions" do
      expect(subject).to be_empty
    end

    context "when promotion has two actions" do
      let(:promotion) { create(:friendly_promotion, :with_adjustable_action, starts_at: Date.yesterday, name: "name1") }

      before do
        promotion.actions << SolidusFriendlyPromotions::Actions::AdjustShipment.new(calculator: SolidusFriendlyPromotions::Calculators::Percent.new)
      end

      it "returns distinct promotion" do
        expect(subject).to match [promotion]
      end
    end
  end

  describe "#apply_automatically" do
    subject { build(:friendly_promotion) }

    it "defaults to false" do
      expect(subject.apply_automatically).to eq(false)
    end

    context "when set to true" do
      before { subject.apply_automatically = true }

      it "remains valid" do
        expect(subject).to be_valid
      end

      it "invalidates the promotion when it has a path" do
        subject.path = "foo"
        expect(subject).not_to be_valid
        expect(subject.errors).to include(:apply_automatically)
      end
    end
  end

  describe "#usage_limit_exceeded?" do
    subject { promotion.usage_limit_exceeded? }

    shared_examples "it should" do
      context "when there is a usage limit" do
        context "and the limit is not exceeded" do
          let(:usage_limit) { 10 }

          it { is_expected.to be_falsy }
        end

        context "and the limit is exceeded" do
          let(:usage_limit) { 1 }

          context "on a different order" do
            before do
              FactoryBot.create(
                :completed_order_with_friendly_promotion,
                promotion: promotion
              )
              promotion.actions.first.adjustments.update_all(eligible: true)
            end

            it { is_expected.to be_truthy }
          end

          context "on the same order" do
            it { is_expected.to be_falsy }
          end
        end
      end

      context "when there is no usage limit" do
        let(:usage_limit) { nil }

        it { is_expected.to be_falsy }
      end
    end

    context "with an item-level adjustment" do
      let(:promotion) do
        FactoryBot.create(
          :friendly_promotion,
          :with_line_item_adjustment,
          code: "discount",
          usage_limit: usage_limit
        )
      end

      before do
        order.friendly_order_promotions.create(
          promotion_code: promotion.codes.first,
          promotion: promotion
        )
        order.recalculate
      end

      context "when there are multiple line items" do
        let(:order) { FactoryBot.create(:order_with_line_items, line_items_count: 2) }

        describe "the first item" do
          let(:promotable) { order.line_items.first }

          it_behaves_like "it should"
        end

        describe "the second item" do
          let(:promotable) { order.line_items.last }

          it_behaves_like "it should"
        end
      end

      context "when there is a single line item" do
        let(:order) { FactoryBot.create(:order_with_line_items) }
        let(:promotable) { order.line_items.first }

        it_behaves_like "it should"
      end
    end
  end

  describe "#usage_count" do
    subject { promotion.usage_count }

    let(:promotion) do
      FactoryBot.create(
        :friendly_promotion,
        :with_line_item_adjustment,
        code: "discount"
      )
    end

    context "when the code is applied to a non-complete order" do
      let(:order) { FactoryBot.create(:order_with_line_items) }

      before do
        order.friendly_order_promotions.create(
          promotion_code: promotion.codes.first,
          promotion: promotion
        )
        order.recalculate
      end

      it { is_expected.to eq 0 }
    end

    context "when the code is applied to a complete order" do
      let!(:order) do
        FactoryBot.create(
          :completed_order_with_friendly_promotion,
          promotion: promotion
        )
      end

      context "and the promo is eligible" do
        it { is_expected.to eq 1 }
      end

      context "and the promo is ineligible" do
        before { order.all_adjustments.friendly_promotion.update_all(eligible: false) }

        it { is_expected.to eq 0 }
      end

      context "and the order is canceled" do
        before { order.cancel! }

        it { is_expected.to eq 0 }
        it { expect(order.state).to eq "canceled" }
      end
    end
  end

  describe "#inactive" do
    let(:promotion) { create(:friendly_promotion, :with_adjustable_action) }

    it "is not expired" do
      expect(promotion).not_to be_inactive
    end

    it "is inactive if it hasn't started yet" do
      promotion.starts_at = Time.current + 1.day
      expect(promotion).to be_inactive
    end

    it "is inactive if it has already ended" do
      promotion.expires_at = Time.current - 1.day
      expect(promotion).to be_inactive
    end

    it "is not inactive if it has started already" do
      promotion.starts_at = Time.current - 1.day
      expect(promotion).not_to be_inactive
    end

    it "is not inactive if it has not ended yet" do
      promotion.expires_at = Time.current + 1.day
      expect(promotion).not_to be_inactive
    end

    it "is not inactive if current time is within starts_at and expires_at range" do
      promotion.starts_at = Time.current - 1.day
      promotion.expires_at = Time.current + 1.day
      expect(promotion).not_to be_inactive
    end
  end

  describe "#not_started?" do
    subject { promotion.not_started? }

    let(:promotion) { described_class.new(starts_at: starts_at) }

    context "no starts_at date" do
      let(:starts_at) { nil }

      it { is_expected.to be_falsey }
    end

    context "when starts_at date is in the past" do
      let(:starts_at) { Time.current - 1.day }

      it { is_expected.to be_falsey }
    end

    context "when starts_at date is not already reached" do
      let(:starts_at) { Time.current + 1.day }

      it { is_expected.to be_truthy }
    end
  end

  describe "#started?" do
    subject { promotion.started? }

    let(:promotion) { described_class.new(starts_at: starts_at) }

    context "when no starts_at date" do
      let(:starts_at) { nil }

      it { is_expected.to be_truthy }
    end

    context "when starts_at date is in the past" do
      let(:starts_at) { Time.current - 1.day }

      it { is_expected.to be_truthy }
    end

    context "when starts_at date is not already reached" do
      let(:starts_at) { Time.current + 1.day }

      it { is_expected.to be_falsey }
    end
  end

  describe "#expired?" do
    subject { promotion.expired? }

    let(:promotion) { described_class.new(expires_at: expires_at) }

    context "when no expires_at date" do
      let(:expires_at) { nil }

      it { is_expected.to be_falsey }
    end

    context "when expires_at date is not already reached" do
      let(:expires_at) { Time.current + 1.day }

      it { is_expected.to be_falsey }
    end

    context "when expires_at date is in the past" do
      let(:expires_at) { Time.current - 1.day }

      it { is_expected.to be_truthy }
    end
  end

  describe "#not_expired?" do
    subject { promotion.not_expired? }

    let(:promotion) { described_class.new(expires_at: expires_at) }

    context "when no expired_at date" do
      let(:expires_at) { nil }

      it { is_expected.to be_truthy }
    end

    context "when expires_at date is not already reached" do
      let(:expires_at) { Time.current + 1.day }

      it { is_expected.to be_truthy }
    end

    context "when expires_at date is in the past" do
      let(:expires_at) { Time.current - 1.day }

      it { is_expected.to be_falsey }
    end
  end

  describe "#active" do
    it "is not active if it has started already" do
      promotion.starts_at = Time.current - 1.day
      expect(promotion.active?).to eq(false)
    end

    it "is not active if it has not ended yet" do
      promotion.expires_at = Time.current + 1.day
      expect(promotion.active?).to eq(false)
    end

    it "is not active if current time is within starts_at and expires_at range" do
      promotion.starts_at = Time.current - 1.day
      promotion.expires_at = Time.current + 1.day
      expect(promotion.active?).to eq(false)
    end

    it "is not active if there are no start and end times set" do
      promotion.starts_at = nil
      promotion.expires_at = nil
      expect(promotion.active?).to eq(false)
    end

    context "when promotion has an action" do
      let(:promotion) { create(:friendly_promotion, :with_adjustable_action, name: "name1") }

      it "is active if it has started already" do
        promotion.starts_at = Time.current - 1.day
        expect(promotion.active?).to eq(true)
      end

      it "is active if it has not ended yet" do
        promotion.expires_at = Time.current + 1.day
        expect(promotion.active?).to eq(true)
      end

      it "is active if current time is within starts_at and expires_at range" do
        promotion.starts_at = Time.current - 1.day
        promotion.expires_at = Time.current + 1.day
        expect(promotion.active?).to eq(true)
      end

      it "is active if there are no start and end times set" do
        promotion.starts_at = nil
        promotion.expires_at = nil
        expect(promotion.active?).to eq(true)
      end

      context "when called with a time" do
        subject { promotion.active?(1.day.ago) }

        context "if promo was active a day ago" do
          before do
            promotion.starts_at = 2.days.ago
            promotion.expires_at = 1.hour.ago
          end

          it { is_expected.to be true }
        end

        context "if promo was not active a day ago" do
          before do
            promotion.starts_at = 1.hour.ago
            promotion.expires_at = 1.day.from_now
          end

          it { is_expected.to be false }
        end
      end
    end
  end

  describe "#products" do
    let(:promotion) { create(:friendly_promotion) }

    context "when it has product rules with products associated" do
      let(:promotion_rule) { SolidusFriendlyPromotions::Rules::Product.new }

      before do
        promotion_rule.promotion = promotion
        promotion_rule.products << create(:product)
        promotion_rule.save
      end

      it "has products" do
        expect(promotion.reload.products.size).to eq(1)
      end
    end

    context "when there's no product rule associated" do
      it "does not have products but still return an empty array" do
        expect(promotion.products).to be_blank
      end
    end
  end

  # regression for https://github.com/spree/spree/issues/4059
  # admin form posts the code and path as empty string
  describe "normalize blank values for path" do
    it "will save blank value as nil value instead" do
      promotion = Spree::Promotion.create(name: "A promotion", path: "")
      expect(promotion.path).to be_nil
    end
  end

  describe "#used_by?" do
    subject { promotion.used_by? user, [excluded_order] }

    let(:promotion) { create :friendly_promotion, :with_adjustable_action }
    let(:user) { create :user }
    let(:order) { create :order_with_line_items, user: user }
    let(:excluded_order) { create :order_with_line_items, user: user }

    before do
      order.user_id = user.id
      order.save!
    end

    context "when the user has used this promo" do
      before do
        order.friendly_order_promotions.create(
          promotion: promotion
        )
        order.recalculate
        order.completed_at = Time.current
        order.save!
      end

      context "when the order is complete" do
        it { is_expected.to be true }

        context "when the promotion was not eligible" do
          let(:adjustment) { order.all_adjustments.first }

          before do
            adjustment.eligible = false
            adjustment.save!
          end

          it { is_expected.to be false }
        end

        context "when the only matching order is the excluded order" do
          let(:excluded_order) { order }

          it { is_expected.to be false }
        end
      end

      context "when the order is not complete" do
        let(:order) { create :order, user: user }

        # The before clause above sets the completed at
        # value for this order
        before { order.update completed_at: nil }

        it { is_expected.to be false }
      end
    end

    context "when the user has not used this promo" do
      it { is_expected.to be false }
    end
  end

  describe ".original_promotion" do
    let(:spree_promotion) { create :promotion, :with_adjustable_action }
    let(:friendly_promotion) { create :friendly_promotion, :with_adjustable_action }

    subject { friendly_promotion.original_promotion }

    it "can be migrated from spree" do
      friendly_promotion.original_promotion = spree_promotion
      expect(subject).to eq(spree_promotion)
    end

    it "is ok to be new" do
      expect(subject).to be_nil
    end
  end
end
