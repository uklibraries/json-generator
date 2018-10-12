#!/usr/bin/env ruby

require 'exifr'
require 'json'
require 'nokogiri'
require 'parallel'

### seek BEGIN

def stopwords
    ['a', 'an', 'as', 'at', 'be', 'but', 'by', 'do', 'for', 'if', 'in', 'is', 'it', 'of', 'on', 'the', 'to']
end

def finding_aid_fields
    {
        :finding_aid_url_s => @finding_aid_url,
        :compound_object_broad_b => true,
        :compound_object_split_b => true,
    }
end

def date_digitized
    if @has_finding_aid
        begin
            @finding_aid_xml.xpath('//xmlns:date[@type="dao"]', @fans).first.content
        rescue
            @mets.xpath('//mets:amdSec//mets:versionStatement', @namespaces).first.content
        end
    else
        @mets.xpath('//mets:amdSec//mets:versionStatement', @namespaces).first.content
    end
end

def title_processed(the_title)
    words = the_title.downcase.gsub(/[^a-z ]/, '').sub(/^insurance\ maps\ of\ /, '').split(/\s+/)
    while stopwords.include?(words.first)
        words.shift
    end
    words.join(' ')
end

def pub_date
    node = @mets.xpath('//dc:date', @namespaces).first
    if node.content
        ret = node.content.strip
        ret.gsub!(/\D/, '')
        ret[0..3]
    else
        ''
    end
end

def full_date_s
    node = @mets.xpath('//dc:date', @namespaces).first
    if node.content
        ret = node.content.strip
        if ret =~ /^\d\d\d\d-\d\d-\d\d/
            ret[0..9]
        elsif ret =~ /^\d\d\d\d-\d\d$/
            ret[0..6]
        elsif ret =~ /^\d\d\d\d/
            ret[0..3]
        else
            ''
        end
    else
        ''
    end
end

def subjects
    @mets.xpath('//dc:subject', @namespaces).collect {|n| n.content.strip}.flatten.uniq
end

def dublin_core_single(field)
    node = @mets.xpath("//dc:#{field}", @namespaces).first
    if node
        node.content.strip
    else
        nil
    end
end

def creator
    node = @mets.xpath('//dc:creator', @namespaces).collect {|n| n}.join('.  ') + '.'
end

def title
    node = @mets.xpath('//dc:title', @namespaces).first
    if node
        node.content.strip
    else
        'unknown title'
    end
end

def xtpath(id)
    'pairtree_root/' + id.gsub(/(..)/, '\1/') + id
end

def dip_field(node, use)
    path = nil
    url = nil
    node.xpath("mets:file[@USE='#{use}']").each do |file|
        flocat = file.xpath('mets:FLocat').first
        path = flocat['xlink:href']
        path.gsub!(/\.\//, '')
        url = [
            'https://nyx.uky.edu/dips',
            @id,
            'data',
            path,
        ].join('/')
    end
    [path, url]
end

### BEGIN

@id = ARGV[0]

#@id = 'xt7kh12v6014'
#@dip_dir = '/opt/shares/library_dips_1/' + xtpath(@id)
@dip_dir = '/opt/shares/library_dips_2/test_dips/' + xtpath(@id)

#solr_dir = '/tmpdir/solr-cache/' + xtpath(@id)
solr_dir = 'solr-cache-old/' + xtpath(@id)
FileUtils.mkdir_p solr_dir

mets_file = File.join @dip_dir, 'data', 'mets.xml'

unless File.exist? mets_file
    STDERR.puts "Can't find METS file #{mets_file}"
    exit 1
end

# <mets:mets xmlns:rights="http://www.loc.gov/rights/" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:lc="http://www.loc.gov/mets/profiles" xmlns:bib="http://www.loc.gov/mets/profiles/bibRecord" xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/" 
# xmlns:mets="http://www.loc.gov/METS/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" OBJID="2008ms006" xsi:schemaLocation="http://www.loc.gov/METS/ http://www.loc.gov/standards/mets/mets.xsd http://www.openarchives.org/OAI/2.0/oai_dc/ http://www.openarchives.org/OAI/2.0/oai_dc.xsd" PROFILE="lc:bibRecord">
# <oai_dc:dc xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/" 
# # xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.openarchives.org/OAI/2.0/oai_dc/     http://www.openarchives.org/OAI/2.0/oai_dc.xsd">
#

# <ead xsi:schemaLocation="urn:isbn:1-931666-22-9 http://www.loc.gov/ead/ead.xsd" 
# xmlns="urn:isbn:1-931666-22-9" xmlns:ns2="http://www.w3.org/1999/xlink" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
#     <eadheader findaidstatus="Completed" repositoryencoding="iso15511" countryencoding="iso3166-1" dateencoding="iso8601" langencoding="iso639-2b">
#

@namespaces = {
    'dc' => "http://purl.org/dc/elements/1.1/",
    'mets' => "http://www.loc.gov/METS/",
}

@fans = {
    'xmlns' => "urn:isbn:1-931666-22-9",
}

@mets = Nokogiri::XML(IO.read(mets_file))

@has_finding_aid = false
@mets.xpath('//mets:fileGrp', @namespaces).each do |node|
    if node['USE'] and node['USE'].downcase =~ /finding\ aid/
        @has_finding_aid = true
        href = node.xpath('//mets:file[@USE="access"]/mets:FLocat').first['xlink:href']
        finding_aid_xml_file = File.join @dip_dir, 'data', href
        @finding_aid_xml = Nokogiri::XML IO.read(finding_aid_xml_file)
        @finding_aid_url = [
            'https://nyx.uky.edu/dips',
            @id,
            'data',
            href,
        ].join('/')
        break
    end
end

core_doc = {
    :creator => creator,
    :title => title,
    :description => dublin_core_single('description'),
    :subjects => subjects,
    :language => dublin_core_single('language'),
    :rights => dublin_core_single('rights'),
    :publisher => dublin_core_single('publisher'),
    :format => dublin_core_single('format'),
    :type => dublin_core_single('type'),
    :relation => dublin_core_single('relation'),
    :coverage => dublin_core_single('coverage'),
    :source => dublin_core_single('source'),
    :contributor => dublin_core_single('contributor'),
}
#puts core_doc.to_json
#exit

mets_url_display = [
    'https://nyx.uky.edu/dips',
    @id,
    'data/mets.xml',
].join('/')

doc = {
    :author_t => core_doc[:creator],
    :author_display => core_doc[:creator],
    :title_t => core_doc[:title],
    :title_display => core_doc[:title],
    :title_sort => core_doc[:title],
    :title_processed_s => title_processed(core_doc[:title]),
    :description_t => core_doc[:description],
    :description_display => core_doc[:description],
    :subject_topic_facet => core_doc[:subjects],
    :pub_date => pub_date,
    :full_date_s => full_date_s,
    :language_display => core_doc[:language],
    :usage_display => core_doc[:rights],
    :publisher_t => core_doc[:publisher],
    :publisher_display => core_doc[:publisher],
    :date_digitized_display => date_digitized,
    :format => core_doc[:format],
    :type_display => core_doc[:type],
    :relation_display => core_doc[:relation],
    :mets_url_display => mets_url_display,
    :coverage_s => core_doc[:coverage],
    :source_s => core_doc[:source],
    :contributor_s => core_doc[:contributor],
}

if @has_finding_aid
    doc.merge! finding_aid_fields
end

if doc.has_key?(:source_s) and doc[:source_s]
    doc[:source_sort_s] = [
        doc[:source_s].strip.downcase,
        '$',
        doc[:source_s],
    ].join('')
end

doc[:object_id_s] = @id

@has_digitized_content = false
@c = 0
@mets.xpath('//mets:fileGrp', @namespaces).reject {|node|
    node['USE'] == 'reel metadata' or node['USE'] == 'wave files'
}.each {|node|
    @c += 1
    if @c > 1
        @has_digitized_content = true
        break
    end
}

doc[:digital_content_available_s] = @has_digitized_content

#puts doc.to_json

# How long does it take to get ids?
#fileGrp_ids = @mets.xpath('//mets:fileGrp', @namespaces).reject {|node|
#    node['USE'] == 'reel metadata' or node['USE'] == 'wave files'
#}.collect {|node|
#    node['ID']
#}

#Parallel.each(@mets.xpath('//mets:fileGrp', @namespaces).reject {|node|
#@mets.xpath('//mets:fileGrp', @namespaces).reject {|node|
#}.each do |node|
#}, in_threads: 24) do |node|
#Parallel.each(@mets.xpath('//mets:fileGrp', @namespaces),
#in_processes: 12) do |node|
#    next if node['USE'] == 'reel metadata' or node['USE'] == 'wave files'
Parallel.each(@mets.xpath('//mets:fileGrp', @namespaces).reject {|node|
    node['USE'] == 'reel metadata' or node['USE'] == 'wave files'
}) do |node|
    copy = doc.dup
    is_finding_aid = false
    if @has_finding_aid and node['USE'] and node['USE'].downcase == 'finding aid'
        copy[:text] = @finding_aid_xml.content
        is_finding_aid = true
    elsif copy.has_key?(:finding_aid_url_s)
        copy.delete(:description_t)
        copy.delete(:description_display)
        copy.delete(:pub_date)
        copy.delete(:subject_topic_facet)
    end
    # generate page
    if is_finding_aid
        # finding_aid_fields
        copy[:title_guide_display] = copy[:title_sort]
        copy[:id] = @id
        #unless copy[:source_s].nil?
        copy[:text] ||= ''
        copy[:text] += copy[:source_s]
        #end
        copy[:text_s] = copy[:text]
        copy[:unpaged_display] = true
        copy[:format] = 'collections'
        copy[:compound_object_broad_b] = true
        copy[:compound_object_split_b] = true
    else
        # paged_page_fields

        # okay, first jump into the structMap
        next unless node.xpath('mets:file').count > 0
        first_file_id = node.xpath('mets:file').first['ID']
        fptr = @mets.xpath("//mets:fptr[@FILEID='#{first_file_id}']").first
        parents = []
        n = fptr
        while n.parent.name == 'div'
            parents.unshift n.parent
            n = n.parent
        end
        copy[:id] = @id + '_' + parents.collect {|n|
            n['ORDER'].strip
        }.join('_')
        div = parents.last
        page_type = div['TYPE']
        the_label =
        if page_type == 'sequence'
            # sequence number display
            div['ORDER'].strip
        else
            # label display
            div['LABEL']
        end
        label_path = parents.collect do |n|
            n['LABEL'].sub(/\s*([,.;:!?]+\s*)+$/, '')
        end
        label_path.pop
        if div['ORDER'].strip.to_i > 1 or @has_finding_aid
            if the_label =~ /^\[?\d+\]?$/
                label_path.push "#{page_type.sub(/^(\w)/){|c|c.capitalize}} #{the_label}"
                copy[:title_display] = "#{label_path.join(' > ')} of #{copy[:title_t]}"
            else
                #label_path.push the_label
                copy[:title_display] = the_label.sub(/\s*([,.;:!?]+\s*)+$/, '')
            end
        end

        copy[:title_guide_display] = copy[:title_sort]
        copy[:title_t] = copy[:title_display]
        copy[:label_display] = div['LABEL']
        copy[:sequence_number_display] = div['ORDER'].strip
        copy[:sequence_sort] = sprintf("%05d", div['ORDER'].strip)
        node.xpath('mets:file[@USE="ocr"]').each do |n|
            flocat = n.xpath('mets:FLocat').first
            text_href = flocat['xlink:href']
            copy[:text] = 
            begin
                IO.read(File.join @dip_dir, 'data', text_href)
            rescue
                ''
            end
            copy[:text_s] = copy[:text]
        end

        # dip field implies nyx link
        lis = dip_field(node, 'reference image')
        @reference_image_path = lis[0]
        copy[:reference_image_url_s] = lis[1]

        copy[:thumbnail_url_s] = dip_field(node, 'thumbnail')[1]
        copy[:front_thumbnail_url_s] = dip_field(node, 'front thumbnail')[1]

        # reference_image_{width,height}_s
        # requires EXIFR
        if @reference_image_path
            path = File.join(
                @dip_dir,
                'data',
                @reference_image_path
            )
            begin
                exifr = EXIFR::JPEG.new(path)
                copy[:reference_image_width_s] = exifr.width.to_i
                copy[:reference_image_height_s] = exifr.height.to_i
            rescue
                STDERR.puts "ERROR: check #{path}"
            end
        end

        copy[:pdf_url_display] = dip_field(node, 'print image')[1]
        copy[:parent_id_s] = copy[:id].sub(/_\d+$/, '')

        alto_href = dip_field(node, 'coordinates')[0]
        if alto_href
            coordinates = {}
            alto_file = File.join @dip_dir, 'data', alto_href
            alto = Nokogiri::XML IO.read(alto_file)
            if alto
                rm_href = dip_field(node, 'reel metadata')[0]
                if rm_href
                    rm = Nokogiri::XML(
                        IO.read(File.join(@dip_dir, 'data', rm_href))
                    )
                    resolution = rm.xpath('//ndnp:captureResolutionOriginal').first.content.to_i
                else
                    begin
                        base_resolution = @mets.xpath('//mets:digiProvMD/mets:process/mets:process_reformat[@FIELDTYPE="reformatInfo"]', @namespaces).first
                        if base_resolution
                            resolution = base_resolution.content.to_i
                        else
                            resolution = 300
                        end
                    rescue
                        resolution = 300
                    end
                end
            end
            resmod = resolution.to_f / 1200
            alto.css('String').each do |string|
                content = string.attribute('CONTENT').text.downcase.strip
                content.gsub!(/\W/, '')
                coordinates[content] ||= []
                coordinates[content] << [
                    'WIDTH',
                    'HEIGHT',
                    'HPOS',
                    'VPOS',
                ].collect do |attribute|
                    string.attribute(attribute).text.to_f * resmod
                end
            end
            copy[:coordinates_display] = coordinates.to_json
        end

        copy[:reference_video_url_s] = dip_field(node, 'reference video')[1]
        copy[:reference_audio_url_s] = dip_field(node, 'reference audio')[1]
        copy[:secondary_reference_audio_url_s] = dip_field(node, 'secondary reference audio')[1]

        if copy[:sequence_number_display].to_i > 1
            copy[:compound_object_broad_b] = false
            copy[:compound_object_split_b] = false
        else
            copy[:compound_object_broad_b] = true
            copy[:compound_object_split_b] = true
        end

        if @has_finding_aid
            copy[:compound_object_broad_b] = false
            copy[:compound_object_split_b] = true
            if copy[:reference_audio_url_s] and copy[:reference_audio_url_s].length > 0
                copy[:format] = 'audio'
            elsif page_type == 'audio'
                copy[:format] = 'audio'
            elsif page_type == 'video'
                copy[:format] = 'audiovisual'
            elsif page_type == 'photograph'
                copy[:format] = 'images'
            elsif page_type == 'sheet'
                copy[:format] = 'maps'
            else
                copy[:format] = 'archival material'
            end

            # get container list
            tag = copy[:id].dup
            if @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']", @fans).count == 0
                tag.gsub!(/_\d+$/, '_1')
            end
            containers = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../xmlns:container", @fans).collect do |container|
                content = container.content.strip
                # get container type
                bad_types = ['folder/item', 'othertype']
                type_candidates = [container['type'], container['label'], 'folder']
                structure = type_candidates.compact.collect {|candidate|
                    candidate.downcase.strip
                }.reject {|candidate|
                    bad_types.include? candidate
                }.first
                %-#{structure} #{content}-
            end
            copy[:container_list_s] = containers.join(', ')

            # get more finding aid related fields
            tag = copy[:id] # unexpected, but this seems to be deliberate in source

            # subjects
            begin
                subjects = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../..//xmlns:subject", @fans).collect do |subject|
                    subject.content
                end
                copy[:subject_topic_facet] = subjects.flatten.uniq
            rescue
            end

            # pub_date
            begin
                unitdate = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../..//xmlns:unitdate", @fans).first.content
                if unitdate =~ /\d\d\d\d/
                    copy[:pub_date] = unitdate.sub(/.*(\d\d\d\d).*/, '\1')
                end
            rescue
            end

            # accession_number_s
            begin
                copy[:accession_number_s] = @finding_aid_xml.xpath("//xmlns:unitid", @fans).first.content.downcase.sub(/^kukav/, '')
            rescue
            end

            # contributor_s
            begin
                copy[:contributor_s] = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../..//xmlns:origination[@label='contributor']", @fans).first.content
            rescue
            end

            # author
            begin
                author = @finding_aids_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../../xmlns:origination[@label='creator']").first.content
                copy[:author_t] = author
                copy[:author_display] = author
            rescue
            end
        end

        copy.keys.each do |key|
            if copy[key].nil?
                copy.delete key
            end
        end
    end

    # browse_key_sort
    begin
        copy[:browse_key_sort] = "#{copy[:title_processed_s][0..0]}#{copy[:sequence_sort]} #{copy[:title_processed_s]}"
    rescue
        copy[:browse_key_sort] = ''
    end

    # cleanup
    copy.each_pair do |key, value|
      if value.class == String
        unless value.valid_encoding?
            copy[key] = value.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '').strip.gsub(/\.\.$/, '.')
        end
      end
    end

    # write result
    output_path = File.join(
        solr_dir,
        copy[:id]
    )

    File.open(output_path, 'w') do |f|
        f.write(copy.to_json)
    end
end
