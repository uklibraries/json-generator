#!/usr/bin/env ruby

require 'find'
require 'json'
require 'parallel'

STOPWORDS = [
    'a', 'an', 'as', 'at', 'be', 'but', 'by', 'do', 'for', 'if', 'in', 'is', 'it', 'of', 'on', 'the', 'to',
]

OBJECT_TYPES = [
    :Collection,
    :Section,
    :Leaf,
    :Audio,
    :Video,
    :Image,
    :Page,
]

DUBLIN_CORE_FIELDS = [
    'contributor',
    'coverage',
    'creator',
    'date',
    'description',
    'format',
    'identifier',
    'language',
    'publisher',
    'relation',
    'rights',
    'source',
    'subject',
    'title',
    'type',
]

def output(json_dir, doc)
    output_path = File.join(
        json_dir,
        doc[:id]
    )

    File.open(output_path, 'w') do |f|
        f.write(doc.to_json)
    end
end

def title_processed(the_title)
    words = the_title.downcase.gsub(/[^a-z ]/, '').sub(/^insurance\ maps\ of\ /, '').split(/\s+/)
    while STOPWORDS.include?(words.first)
        words.shift
    end
    words.join(' ')
end

def xtpath(id)
    'pairtree_root/' + id.gsub(/(..)/, '\1/') + id
end

@id = ARGV[0]
@dip_dir = '/opt/shares/library_dips_2/test_dips/' + xtpath(@id)
json_dir = '/tmpdir/json-cache/' + xtpath(@id)
solr_dir = '/tmpdir/solr-cache/' + xtpath(@id)
#mets_file = File.join @dip_dir, 'data', 'mets.xml'
FileUtils.mkdir_p json_dir
FileUtils.mkdir_p solr_dir
FileUtils.rm_rf solr_dir
FileUtils.mkdir_p solr_dir

#Find.find(json_dir) do |path|
Parallel.each(Find.find(json_dir)) do |path|
    if FileTest.directory?(path)
        if File.basename(path)[0] == ?.
            Find.prune
        else
            next
        end
    elsif File.file?(path)
        name = File.basename(path)
        json = JSON.parse(IO.read(path), symbolize_names: true)
        solr = {}

        solr[:leaf_count_i] = json[:leaf_count]
        solr[:object_type_s] = json[:object_type]
        solr[:top_level_b] = json[:top_level]

        DUBLIN_CORE_FIELDS.each do |fieldname|
            solr["dc_#{fieldname}_display".to_sym] = json[fieldname.to_sym]
            solr["dc_#{fieldname}_t".to_sym] = json[fieldname.to_sym]
        end

        solr[:accession_number_s] = json[:accession_number]

        # XXX
        author = json[:creator].join('.  ') + '.'
        solr[:author_display] = author
        solr[:author_t] = author

        if ['collection', 'section', 'audio', 'video', 'image'].include? json[:object_type]
            solr[:compound_object_split_b] = true
        else
            solr[:compound_object_split_b] = false
        end

        solr[:container_list_s] = json[:container_list]
        solr[:contributor_s] = json[:contributor]
        solr[:coordinates_display] = json[:coordinates]
        solr[:coverage_s] = json[:coverage]
        solr[:date_digitized_display] = json[:upload_date]
        unless json[:description].nil?
            solr[:description_display] = json[:description].first
            solr[:description_t] = json[:description].first
        end
        solr[:digital_content_available_s] = json[:digital_content_available]
        solr[:finding_aid_url_s] = json[:finding_aid_url]
        
        # XXX
        solr[:format] = json[:format].first

        solr[:front_thumbnail_url_s] = json[:front_thumbnail_url]
        solr[:id] = json[:id]
        unless json[:language].nil?
            solr[:language_display] = json[:language].first
        end
        solr[:mets_url_display] = json[:mets_url]
        solr[:object_id_s] = json[:object_id]
        solr[:parent_id_s] = json[:parent_id]
        solr[:pdf_url_display] = json[:pdf_url]
        solr[:pub_date] = json[:creation_date]
        unless json[:publisher].nil?
            solr[:publisher_display] = json[:publisher].first
            solr[:publisher_t] = json[:publisher].first
        end
        solr[:reference_audio_url_s] = json[:reference_audio_url]
        solr[:reference_image_height_s] = json[:reference_image_height]
        solr[:reference_image_url_s] = json[:reference_image_url]
        solr[:reference_image_width_s] = json[:reference_image_width]
        solr[:reference_video_url_s] = json[:reference_video_url]
        solr[:relation_display] = json[:relation]
        solr[:secondary_reference_audio_url_s] = json[:secondary_reference_audio_url]
        unless json[:position].nil?
            solr[:sequence_number_display] = json[:position].to_s
            solr[:sequence_sort] = sprintf("%05d", json[:position].to_i)
        end
        unless json[:source].nil? or json[:source].empty?
            solr[:source_s] = json[:source].first
            solr[:source_sort_s] = [
                json[:source].first.strip.downcase,
                '$',
                json[:source].first,
            ].join('')
        end
        solr[:subject_topic_facet] = json[:subject]
        unless json[:text].nil?
            solr[:text] = json[:text]
            solr[:text_s] = (json[:text] || "")[0, 32767]
        end
        solr[:thumbnail_url_s] = json[:thumbnail_url]

        # XXX
        solr[:title_display] = json[:title].first
        solr[:title_processed_s] = title_processed(json[:title_object])
        solr[:title_sort] = json[:title_object]
        solr[:title_t] = json[:title].first
        
        unless json[:type].nil?
            solr[:type_display] = json[:type].first
        end
        unless json[:rights].nil?
            solr[:usage_display] = json[:rights].first
        end

        # XXX at end
        begin
            solr[:browse_key_sort] = "#{solr[:title_processed_s][0..0]}#{solr[:sequence_sort]} #{solr[:title_processed_s]}"
        rescue
            solr[:browse_key_sort] = ""
        end

        solr.each_pair do |key, value|
            if value.class == String
                unless value.valid_encoding?
                    solr[key] = value.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '').strip.gsub(/\.\.$/, '.')
                end
            elsif value.nil? or (value.kind_of?(Array) && value.count == 0)
                solr.delete(key)
            end
        end

        output(solr_dir, solr)
    end
end
