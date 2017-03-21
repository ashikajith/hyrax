# Responsible for persisting the ownership transfer requests and the state of each request.
# @see ProxyDepositRequest.enum(:status)
# @see ProxyDepositRequest.work_query_service_class for configuration (defaults to Hyrax::WorkQueryService)
# @see Hyrax::WorkQueryService
class ProxyDepositRequest < ActiveRecord::Base
  include ActionView::Helpers::UrlHelper

  class_attribute :work_query_service_class
  self.work_query_service_class = Hyrax::WorkQueryService

  delegate :deleted_work?, :work, :to_s, to: :work_query_service

  private

    def work_query_service
      @work_query_service ||= work_query_service_class.new(id: work_id)
    end

  public

  belongs_to :receiving_user, class_name: 'User'
  belongs_to :sending_user, class_name: 'User'

  # @param [User] user - the person who needs to take action on the ownership transfer request
  # @return [Enumerable] a set of requests that the given user can act upon to claim the ownership transfer
  # @note We are iterating through the found objects and querying SOLR each time. Assuming we are rendering this result in a view,
  #       this is reasonable. In the view we will render the #to_s of the associated work. So we may as well preload the SOLR document.
  def self.incoming_for(user:)
    where(receiving_user: user).reject(&:deleted_work?)
  end

  # @param [User] user - the person who requested that a work be transfer to someone else
  # @return [Enumerable] a set of requests created by the given user
  # @todo Should I skip deleted works as indicated in the .incoming_for method?
  def self.outgoing_for(user:)
    where(sending_user: user)
  end

  # attribute work_id exists as result of renaming in db migrations.
  # See upgrade700_generator.rb

  validates :sending_user, :work_id, presence: true
  validate :transfer_to_should_be_a_valid_username
  validate :sending_user_should_not_be_receiving_user
  validate :should_not_be_already_part_of_a_transfer

  after_save :send_request_transfer_message

  # @param [String] user_key - The key of the user that will receive the transfer
  # @note The HTML form for creating a ProxyDepositRequest requires this method
  def transfer_to=(user_key)
    self.receiving_user = User.find_by_user_key(user_key)
  end

  # @return [nil, String] nil if we don't have a receiving user, otherwise it returns the receiving_user's user_key
  # @note The HTML form for creating a ProxyDepositRequest requires this method
  # @see User#user_key
  def transfer_to
    receiving_user.try(:user_key)
  end

  def transfer_to_should_be_a_valid_username
    errors.add(:transfer_to, "must be an existing user") unless receiving_user
  end

  def sending_user_should_not_be_receiving_user
    errors.add(:sending_user, 'must specify another user to receive the work') if receiving_user && receiving_user.user_key == sending_user.user_key
  end

  def should_not_be_already_part_of_a_transfer
    transfers = ProxyDepositRequest.where(work_id: work_id, status: PENDING)
    errors.add(:open_transfer, 'must close open transfer on the work before creating a new one') unless transfers.blank? || (transfers.count == 1 && transfers[0].id == id)
  end

  def send_request_transfer_message
    if updated_at == created_at
      send_request_transfer_message_as_part_of_create
    else
      send_request_transfer_message_as_part_of_update
    end
  end

  private

    def send_request_transfer_message_as_part_of_create
      user_link = link_to(sending_user.name, Hyrax::Engine.routes.url_helpers.profile_path(sending_user.user_key))
      transfer_link = link_to('transfer requests', Hyrax::Engine.routes.url_helpers.transfers_path)
      message = "#{user_link} wants to transfer a work to you. Review all #{transfer_link}"
      User.batch_user.send_message(receiving_user, message, "Ownership Change Request")
    end

    def send_request_transfer_message_as_part_of_update
      message = "Your transfer request was #{status}."
      message += " Comments: #{receiver_comment}" unless receiver_comment.blank?
      User.batch_user.send_message(sending_user, message, "Ownership Change #{status}")
    end

  public

  ACCEPTED = 'accepted'.freeze
  PENDING = 'pending'.freeze
  CANCELED = 'canceled'.freeze
  REJECTED = 'rejected'.freeze

  enum(
    status: {
      ACCEPTED => ACCEPTED,
      CANCELED => CANCELED,
      PENDING => PENDING,
      REJECTED => REJECTED
    }
  )

  # @param [TrueClass,FalseClass] reset (false)  if true, reset the access controls. This revokes edit access from the depositor
  def transfer!(reset = false)
    ContentDepositorChangeEventJob.perform_later(work, receiving_user, reset)
    fulfill!(status: ACCEPTED)
  end

  # @param [String, nil] comment - A given reason by the rejecting user
  def reject!(comment = nil)
    fulfill!(status: REJECTED, comment: comment)
  end

  def cancel!
    fulfill!(status: CANCELED)
  end

  private

    def fulfill!(status:, comment: nil)
      self.receiver_comment = comment if comment
      self.status = status
      self.fulfillment_date = Time.current
      save!
    end
end
