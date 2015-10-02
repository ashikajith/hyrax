class FulltextExtractionJob < ActiveFedoraIdBasedJob
  queue_as :fulltext

  # @param [String] id
  # @param [String] filename a local path for the file to extract fulltext. By using this, we don't have to pull a copy out of fedora.
  def perform(id, filename)
    @id = id
    store_fulltext(Hydra::Works::FullTextExtractionService.run(generic_file, filename))
    generic_file.save
  end

  def store_fulltext(extracted_text)
    return unless extracted_text.present?
    extracted_text_file = generic_file.build_extracted_text
    extracted_text_file.content = extracted_text
  end
end
