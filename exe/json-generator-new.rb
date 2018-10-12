#!/usr/bin/env ruby

require 'exifr'
require 'json'
require 'nokogiri'
require 'parallel'

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

def date_recognizer(lis)
    if lis.nil?
        ''
    elsif lis.count > 0
        date = lis.first
        date.gsub!(/\D/, '')
        date[0..3]
    else
        ''
    end
end

def dip_path(node, re)
    fptr = node.children.select {|n|
        n['FILEID'] =~ re
    }.first
    if fptr
        file_id = fptr['FILEID']
        flocat = @mets.xpath("//mets:file[@ID='#{file_id}']//mets:FLocat", @namespaces).first
        if flocat.nil?
            STDERR.puts "bad flocat for #{file_id}"
        end
        href = flocat['xlink:href']
        href.sub(%r{\./}, '')
    else
        nil
    end
end

def dip_url(node, re)
    href = dip_path(node, re)
    if href
        urlify(href)
    else
        nil
    end
end

def output(json_dir, doc)
    output_path = File.join(
        json_dir,
        doc[:id]
    )

    File.open(output_path, 'w') do |f|
        doc.each_pair do |key, value|
            if value.class == String
                unless value.valid_encoding?
                    doc[key] = value.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '').strip.gsub(/\.\.$/, '.')
                end
            end
        end
        f.write(doc.to_json)
    end
end

def urlify(href)
    href.gsub!(%r{\./}, '')
    [
        'https://nyx.uky.edu/dips',
        @id,
        'data',
        href,
    ].join('/')
end

def xtpath(id)
    'pairtree_root/' + id.gsub(/(..)/, '\1/') + id
end

@id = ARGV[0]
@dip_dir = '/opt/shares/library_dips_2/test_dips/' + xtpath(@id)
json_dir = '/tmpdir/json-cache/' + xtpath(@id)
mets_file = File.join @dip_dir, 'data', 'mets.xml'

unless File.exist? mets_file
    STDERR.puts "Can't find METS file #{mets_file}"
    exit 1
end

FileUtils.mkdir_p json_dir

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

core_doc = {
    :id => @id,
    :mets_url => [
        'https://nyx.uky.edu/dips',
        @id,
        'data/mets.xml',
    ].join('/'),
}

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
        core_doc[:finding_aid_url] = @finding_aid_url
        break
    end
end

DUBLIN_CORE_FIELDS.each do |fieldname|
    entry = fieldname.to_sym
    core_doc[entry] = []
    @mets.xpath("//mets:dmdSec[@ID='DMD1']//dc:#{fieldname}", @namespaces).each do |node|
        core_doc[entry] << node.content.strip
    end
end

unless core_doc[:title].count == 0
    core_doc[:title_object] = core_doc[:title].first
end

# specific field cleanup
core_doc[:language].map!(&:capitalize)
core_doc[:rights].map! do |entry|
    entry.gsub(%r{Please go to http://kdl\.kyvl\.org for more information\.}, 'For information about permissions to reproduce or publish, <a href="https://libraries.uky.edu/ContactSCRC" target="_blank" rel="noopener">contact the Special Collections Research Center</a>.')
end

core_doc[:creation_date] = date_recognizer(core_doc[:date])
core_doc[:upload_date] = @mets.xpath('//mets:amdSec//mets:versionStatement', @namespaces).first.content.strip

dip_doc = core_doc.dup
dip_doc[:top_level] = true
dip_doc[:object_id] = @id

if @has_finding_aid
#if core_doc[:format].include? 'collections'
    dip_object_type = :Collection
    dip_doc[:object_type] = "collection"

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
    dip_doc[:digital_content_available] = @has_digitized_content
    if @has_digitized_content
        dip_doc[:accession_number] = @finding_aid_xml.xpath("//xmlns:unitid", @fans).first.content.downcase.sub(/^kukav/, '')
    end

    text_pieces = []
    dip_doc.each_pair do |key, value|
        if value.kind_of?(Array)
            value.each do |item|
                text_pieces << item
            end
        else
            text_pieces << value.to_s
        end
    end
    @finding_aid_xml.search('//text()').each do |node|
        text_pieces << node.text
    end
    dip_doc[:text] = text_pieces.join(' ')
else
    dip_object_type = :Section
    dip_doc[:object_type] = 'section'
    dip_doc[:top_level] = true
    dip_doc[:id] = @id
    dip_doc[:object_id] = @id
    dip_doc[:parent_id] = @id
    leaves = 0
    text_pieces = []
    dip_doc.each_pair do |key, value|
        if value.kind_of?(Array)
            value.each do |item|
                text_pieces << item
            end
        else
            text_pieces << value.to_s
        end
    end
    @mets.xpath('//mets:structMap/mets:div').each do |div|
        leaves += 1
        text_path = dip_path(div, /^Ocr/)
        if text_path
            text_pieces << IO.read(File.join @dip_dir, 'data', text_path)
        end
    end
    dip_doc[:text] = text_pieces.join(' ')
    dip_doc[:leaf_count] = leaves

    if leaves > 0
        first_leaf = @mets.xpath('//mets:structMap/mets:div').first

        ref_image_check = dip_path(first_leaf, /^ReferenceImage/)
        if ref_image_check
            dip_doc[:reference_image_url] = dip_url(first_leaf, /^ReferenceImage/)
            reference_image_path = File.join(
                @dip_dir,
                'data',
                dip_path(first_leaf, /^ReferenceImage/),
            )
            begin
                exifr = EXIFR::JPEG.new(reference_image_path)
                dip_doc[:reference_image_width] = exifr.width.to_i
                dip_doc[:reference_image_height] = exifr.height.to_i
            rescue
                STDERR.puts "ERROR: check #{reference_image_path}"
            end

            dip_doc[:thumbnail_url] = dip_url(first_leaf, /^Thumbnail/)
            dip_doc[:front_thumbnail_url] = dip_url(first_leaf, /^FrontThumbnail/)
        else
            ref_audio_check = dip_path(first_leaf, /^ReferenceAudio/)
            if ref_audio_check
                dip_doc[:reference_audio_url] = dip_url(first_leaf, /^ReferenceAudio/)
            end
        end
    end
end

output(json_dir, dip_doc)

Parallel.each(@mets.xpath('//mets:div', @namespaces)) do |node|
#Parallel.each(@mets.xpath('//mets:div', @namespaces), in_threads: 8) do |node|
#Parallel.each(@mets.xpath('//mets:div', @namespaces), in_threads: 48) do |node|
#@mets.xpath('//mets:div', @namespaces).each do |node|
    case node['TYPE']
    when 'section'
        doc = core_doc.dup
        doc[:object_type] = 'section'
        doc[:top_level] = false
        parents = []
        n = node.children.first

# take a moment to figure out first-page metadata
# begin first-page metadata
        nt = n['TYPE']

        if n['LABEL'] =~ /\D/
            doc[:title] = [n['LABEL'].strip.gsub(/\s*([,.;:!?]+\s*)+$/, '')]
            doc[:title_object] = doc[:title]
        end

        if dip_path(n, /^ReferenceVideo/)
            nt = 'video'
        elsif dip_path(n, /^ReferenceAudio/)
            nt = 'audio'
        end

        case nt
        when 'audio'
            doc[:format] = ['audio']
        when 'video'
            doc[:format] = ['audiovisual']
        when 'photograph'
            doc[:format] = ['images']
        else
            if doc.include? :finding_aid_url
                case node['TYPE']
                when 'sheet'
                    doc[:format] = ['maps']
                else
                    doc[:format] = ['archival material']
                end
            end
        end
# end first-page metadata

        while n.parent.name == 'div'
            parents.unshift n.parent
            n = n.parent
        end
        doc[:id] = @id + '_' + parents.collect {|n|
            n['ORDER'].strip
        }.join('_')

        doc[:object_id] = doc[:id]
        doc[:parent_id] = doc[:id].sub(/_[^_]+$/, '')

        leaves = 0
        text_pieces = []
        doc.each_pair do |key, value|
            if value.kind_of?(Array)
                value.each do |item|
                    text_pieces << item
                end
            else
                text_pieces << value.to_s
            end
        end
        node.xpath('mets:div').each do |div|
            leaves += 1
            text_path = dip_path(div, /^Ocr/)
            if text_path
                text_pieces << IO.read(File.join @dip_dir, 'data', text_path)
            end
        end
        doc[:text] = text_pieces.join(' ')
        doc[:leaf_count] = leaves

        if leaves > 0
            first_leaf = node.xpath('mets:div').first

            ref_image_check = dip_path(first_leaf, /^ReferenceImage/)
            if ref_image_check
                doc[:reference_image_url] = dip_url(first_leaf, /^ReferenceImage/)
                reference_image_path = File.join(
                    @dip_dir,
                    'data',
                    dip_path(first_leaf, /^ReferenceImage/),
                )
                begin
                    exifr = EXIFR::JPEG.new(reference_image_path)
                    doc[:reference_image_width] = exifr.width.to_i
                    doc[:reference_image_height] = exifr.height.to_i
                rescue
                    STDERR.puts "ERROR: check #{reference_image_path}"
                end

                doc[:thumbnail_url] = dip_url(first_leaf, /^Thumbnail/)
                doc[:front_thumbnail_url] = dip_url(first_leaf, /^FrontThumbnail/)
            else
                ref_audio_check = dip_path(first_leaf, /^ReferenceAudio/)
                if ref_audio_check
                    doc[:reference_audio_url] = dip_url(first_leaf, /^ReferenceAudio/)
                end
            end
        end
    else
        doc = dip_doc.dup
        doc.delete(:description)
        doc.delete(:subject)
        doc.delete(:text)
        doc[:top_level] = false
        parents = []
        n = node.children.first
        while n.parent.name == 'div'
            parents.unshift n.parent
            n = n.parent
        end
        doc[:id] = @id + '_' + parents.collect {|n|
            n['ORDER'].strip
        }.join('_')

        # object_id
        doc[:object_id] = doc[:id].sub(/_\d+$/, '')

        # parent_id
        doc[:parent_id] = doc[:id].sub(/_\d+$/, '')

        # position
        doc[:position] = node['ORDER'].to_i

        # container_list
        if @finding_aid_xml
            tag = doc[:id].dup
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
            doc[:container_list] = containers.join(', ')

            # creation_date
            unitdate = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../..//xmlns:unitdate", @fans).first
            unless unitdate.nil?
                unitdate = unitdate.content
                if unitdate =~ /\d\d\d\d/
                    doc[:creation_date] = unitdate.sub(/.*(\d\d\d\d).*/, '\1')
                end
            end

            # contributor
            orig = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../..//xmlns:origination[@label='contributor']", @fans).first
            unless orig.nil?
                doc[:contributor] = [orig.content]
            end

            # creator
            auth = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}']/../..//xmlns:origination[@label='creator']", @fans).first
            unless auth.nil?
                doc[:creator] = [auth.content]
            end
        end

        # title
        if node['LABEL'] =~ /\D/
            doc[:title] = [node['LABEL'].strip.gsub(/\s*([,.;:!?]+\s*)+$/, '')]
        end

        if dip_path(node, /^ReferenceVideo/)
            node['TYPE'] = 'video'
        elsif dip_path(node, /^ReferenceAudio/)
            node['TYPE'] = 'audio'
        end

        case node['TYPE']
        when 'audio'
            doc[:object_type] = 'audio'
            doc[:format] = ['audio']
            doc[:reference_audio_url] = dip_url(node, /^ReferenceAudio/)
            doc[:secondary_reference_audio_url] = dip_url(node, /^SecondaryReferenceAudio/)
        when 'video'
            doc[:object_type] = 'video'
            doc[:format] = ['audiovisual']
            doc[:reference_video_url] = dip_url(node, /^ReferenceVideo/)
        when 'photograph'
            doc[:object_type] = 'image'
            doc[:format] = ['images']
            doc[:reference_image_url] = dip_url(node, /^ReferenceImage/)
            path = dip_path(node, /^ReferenceImage/)
            unless path
                STDERR.puts "bad ref image in #{node.to_xml}"
            end
            reference_image_path = File.join(
                @dip_dir,
                'data',
                dip_path(node, /^ReferenceImage/),
            )
            begin
                exifr = EXIFR::JPEG.new(reference_image_path)
                doc[:reference_image_width] = exifr.width.to_i
                doc[:reference_image_height] = exifr.height.to_i
            rescue
                STDERR.puts "ERROR: check #{reference_image_path}"
            end

            doc[:thumbnail_url] = dip_url(node, /^Thumbnail/)
            doc[:front_thumbnail_url] = dip_url(node, /^FrontThumbnail/)
            doc[:pdf_url] = dip_url(node, /^PrintImage/)
        else
            if doc.include? :finding_aid_url
                case node['TYPE']
                when 'sheet'
                    doc[:format] = ['maps']
                else
                    doc[:format] = ['archival material']
                end
            end

            doc['object_type'] = 'page'
            doc[:reference_image_url] = dip_url(node, /^ReferenceImage/)
            if dip_path(node, /^ReferenceImage/).nil?
                STDERR.puts doc[:id] + ' ' + node.to_xml
            end
            reference_image_path = File.join(
                @dip_dir,
                'data',
                dip_path(node, /^ReferenceImage/),
            )
            begin
                exifr = EXIFR::JPEG.new(reference_image_path)
                doc[:reference_image_width] = exifr.width.to_i
                doc[:reference_image_height] = exifr.height.to_i
            rescue
                STDERR.puts "ERROR: check #{reference_image_path}"
            end

            doc[:thumbnail_url] = dip_url(node, /^Thumbnail/)
            doc[:front_thumbnail_url] = dip_url(node, /^FrontThumbnail/)
            doc[:pdf_url] = dip_url(node, /^PrintImage/)
            text_path = dip_path(node, /^Ocr/)
            if text_path
                doc[:text] = IO.read(File.join @dip_dir, 'data', text_path)
            end
            doc[:coordinates] = dip_url(node, /^Coordinates/)
        end
    end

    output(json_dir, doc)
end
