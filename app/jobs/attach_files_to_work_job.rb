# frozen_string_literal: true
# Converts UploadedFiles into FileSets and attaches them to works.
class AttachFilesToWorkJob < Hyrax::ApplicationJob
  queue_as Hyrax.config.ingest_queue_name

  # @param [ActiveFedora::Base] work - the work object
  # @param [Array<Hyrax::UploadedFile>] uploaded_files - an array of files to attach
  def perform(work, uploaded_files, **work_attributes)
    case work
    when ActiveFedora::Base
      perform_af(work, uploaded_files, work_attributes)
    else
      Hyrax::WorkUploadsHandler.new(work: work).add(files: uploaded_files).attach ||
        raise("Could not complete AttachFilesToWorkJob. Some of these are probably in an undesirable state: #{uploaded_files}")
    end
  end

  private

  def perform_af(work, uploaded_files, work_attributes)
    validate_files!(uploaded_files)
    depositor = proxy_or_depositor(work)
    user = User.find_by_user_key(depositor)

    work, work_permissions = create_permissions work, depositor
    uploaded_files.each do |uploaded_file|
      next if uploaded_file.file_set_uri.present?

      actor = Hyrax::Actors::FileSetActor.new(FileSet.create, user)
      metadata = visibility_attributes(work_attributes, uploaded_file)
      uploaded_file.add_file_set!(actor.file_set)
      actor.file_set.permissions_attributes = work_permissions
      actor.create_metadata(metadata)
      actor.create_content(uploaded_file)
      actor.attach_to_work(work, metadata)
    end
  end

  def create_permissions(work, depositor)
    work.edit_users += [depositor]
    work.edit_users = work.edit_users.dup
    work_permissions = work.permissions.map(&:to_hash)
    [work, work_permissions]
  end

  # The attributes used for visibility - sent as initial params to created FileSets.
  def visibility_attributes(attributes, uploaded_file = nil)
    file_set_attributes = Array(attributes[:file_set]).find { |fs| fs[:uploaded_file_id] == uploaded_file&.id }
    attributes.merge(Hash(file_set_attributes)).slice(:visibility, :visibility_during_lease,
                     :visibility_after_lease, :lease_expiration_date,
                     :embargo_release_date, :visibility_during_embargo,
                     :visibility_after_embargo)
  end

  def validate_files!(uploaded_files)
    uploaded_files.each do |uploaded_file|
      next if uploaded_file.is_a? Hyrax::UploadedFile
      raise ArgumentError, "Hyrax::UploadedFile required, but #{uploaded_file.class} received: #{uploaded_file.inspect}"
    end
  end

  ##
  # A work with files attached by a proxy user will set the depositor as the intended user
  # that the proxy was depositing on behalf of. See tickets #2764, #2902.
  def proxy_or_depositor(work)
    work.on_behalf_of.presence || work.depositor
  end
end
