#!/usr/bin/env ruby

require 'exifr'
require 'exifr/jpeg'
require 'json'
require 'nokogiri'
require 'parallel'

@namespaces = {
    'dc' => 'http://purl.org/dc/elements/1.1/',
    'mets' => 'http://www.loc.gov/METS/',
}

@fans = {
    'xmlns' => 'urn:isbn:1-931666-22-9',
}

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

#def process_dip(json_dir)
#    core_doc = build_core_doc()
#end

def process_dip_object(core_doc)
    @dip_doc = core_doc.dup
    @dip_doc[:top_level] = true
    @dip_doc[:object_id] = @id

    if @has_finding_aid
        dip_object_type = :Collection
        @dip_doc[:object_type] = 'collection'
        @dip_doc[:format] = ['collections']

        @has_digitized_content = false
        @c = 0
        @mets.xpath('//mets:fileGrp', @namespaces).reject {|node|
            node['USE'] == 'reel metadata' or node['USE'] =~ /wave file/
        }.each {|node|
            @c += 1
            if @c > 1
                @has_digitized_content = true
                break
            end
        }
        @dip_doc[:digital_content_available] = @has_digitized_content
        if @has_digitized_content
            @dip_doc[:accession_number] = @finding_aid_xml.xpath('//xmlns:unitid', @fans).first.content.downcase.sub(/^kukav/, '')
        end

        text_pieces = []
        @dip_doc.each_pair do |key, value|
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
        @dip_doc[:text] = text_pieces.join(' ')

        output(@json_dir, @dip_doc)
    else
        # booklike section
        dip_object_type = :Section
        @dip_doc[:object_type] = 'section'
        @dip_doc[:top_level] = true
        @dip_doc[:id] = @id # necessary?
        @dip_doc[:object_id] = @id
        @dip_doc[:parent_id] = @id
        leaves = 0
        text_pieces = []
        @dip_doc.each_pair do |key, value|
            if value.kind_of?(Array)
                value.each do |item|
                    text_pieces << item
                end
            else
                text_pieces << value.to_s
            end
        end
        @mets.xpath('//mets:structMap/mets:div', @namespaces).each do |div|
            leaves += 1
            text_path = dip_path(div, /^Ocr/)
            if text_path
                text_pieces << IO.read(File.join @dip_dir, 'data', text_path)
            end
        end
        @dip_doc[:text] = text_pieces.join(' ')
        @dip_doc[:leaf_count] = leaves

        if leaves > 0
            # function?
            first_leaf = @mets.xpath('//mets:structMap/mets:div', @namespaces).first

            ref_image_check = dip_path(first_leaf, /^ReferenceImage/)
            if ref_image_check
                @dip_doc[:reference_image_url] = dip_url(first_leaf, /^ReferenceImage/)
                reference_image_path = File.join(
                    @dip_dir,
                    'data',
                    dip_path(first_leaf, /^ReferenceImage/), # ref_image_check
                )
                begin
                    exifr = EXIFR::JPEG.new(reference_image_path)
                    @dip_doc[:reference_image_width] = exifr.width.to_i
                    @dip_doc[:reference_image_height] = exifr.height.to_i
                rescue
                    STDERR.puts "ERROR: check #{reference_image_path}"
                end

                @dip_doc[:thumbnail_url] = dip_url(first_leaf, /^Thumbnail/)
                @dip_doc[:front_thumbnail_url] = dip_url(first_leaf, /^FrontThumbnail/)
            else
                ref_audio_check = dip_path(first_leaf, /^ReferenceAudio/)
                if ref_audio_check
                    @dip_doc[:reference_audio_url] = dip_url(first_leaf, /^ReferenceAudio/)
                end
            end
        end

        # Check for multipage
        multipage = @mets.xpath('//mets:fileGrp[@ID="FileGrpMultipage"]', @namespaces)
        if multipage.count > 0
            flocat = @mets.xpath('//mets:fileGrp[@ID="FileGrpMultipage"]//mets:file//mets:FLocat', @namespaces).first
            if flocat.nil?
                STDERR.puts "bad flocat for multipage"
            end
            href = flocat['xlink:href']
            href.sub!(%r{\./}, '')
            @dip_doc[:pdf_url] = urlify(href)
        end

        format = @dip_doc[:format].first
        if format != 'audio' && format != 'audiovisual' && format != 'drawings (visual works)' && format != 'images'
            # possibly pageable
            output(@json_dir, @dip_doc)
        end
    end
end

def process_section(section, core_doc)
    doc = core_doc.dup
    order = section['ORDER'].strip
    doc[:id] = [core_doc[:id], order].join('_')
    #puts ":creation_date was #{doc[:creation_date]}"
    #doc.delete(:creation_date)
    #puts "* #{doc[:id]}"

    if @finding_aid_xml
        doc.delete(:creation_date)
        doc.delete(:creation_full_date)
        # check for PDF
        url = dip_url(section, /^PrintImage/)
        if url
            doc[:pdf_url] = url
        end

        # creation_date
        tag = doc[:id].dup
        unitdate = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}_1']/../..//xmlns:unitdate", @fans).first
        unless unitdate.nil?
            unitdate = unitdate.content.strip
            if unitdate =~ /\d\d\d\d/
                doc[:creation_date] = unitdate.sub(/.*(\d\d\d\d).*/, '\1')
                doc[:creation_full_date] = unitdate
            end
        end

        # title
        dao_ancestors = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}_1']/../../ancestor::*", @fans).reverse
        dao_ancestors.each do |ancestor|
            break if ancestor.name == 'dsc'
            unittitle = ancestor.xpath('.//xmlns:unittitle', @fans).first
            unless unittitle.nil?
                unittitle = unittitle.content.strip
                if unittitle.length > 0
                    doc[:title] = [unittitle]
                    doc[:title_object] = doc[:title].first
                    break
                end
            end
        end
        #unittitles.each do |ut|
        #    if ut.name == 'dsc'
        #        break
        #    end
        #    puts ut.to_xml
        #    STDOUT.flush
        #end
#        unittitle = @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}_1']/../..//xmlns:unittitle", @fans).first
#        unless unittitle.nil?
#            unittitle = unittitle.content.strip
#            if unittitle.length > 0
#                doc[:title] = [unittitle]
#                doc[:title_object] = doc[:title].first
#            end
#        else
#            puts "#{doc[:id]}: no unittitle for #{tag}_1 / #{doc[:title_object]}"
#            puts @finding_aid_xml.xpath("//xmlns:dao[@entityref='#{tag}_1']/../..", @fans).to_xml
#            STDOUT.flush
#        end
    end

    #puts section.xpath('mets:div', @namespaces).count
    #Parallel.each(section.xpath('mets:div', @namespaces)) do |leaf|
    first_format = nil
    #puts "** #{doc[:id]}: processing leaves"
    section.xpath('mets:div', @namespaces).each do |leaf|
        #process_leaf(leaf, doc)
        leaf_format = process_leaf(leaf, doc)
        if first_format.nil?
            first_format = leaf_format
        end
    end

    doc[:object_type] = 'section'
    doc[:top_level] = false
    parents = []
    n = section.xpath('mets:div', @namespaces).first

# take a moment to figure out first-page metadata
# begin first-page metadata
    nt = n['TYPE']

    if n['LABEL'] =~ /\D/
        doc[:title] = [n['LABEL'].strip.gsub(/\s*([,.;:!?]+\s*)+$/, '')]
        doc[:title_object] = doc[:title].first
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
            case section['TYPE']
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
    section.xpath('mets:div').each do |div|
        leaves += 1
        text_path = dip_path(div, /^Ocr/)
        if text_path
            text_pieces << IO.read(File.join @dip_dir, 'data', text_path)
        end
    end
    doc[:text] = text_pieces.join(' ')
    doc[:leaf_count] = leaves

    if leaves > 0
        first_leaf = section.xpath('mets:div').first

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

    if leaves > 0
        #format = doc[:format].first # first_format
        format = first_format
        if format != 'audio' && format != 'audiovisual' && format != 'drawings (visual works)' && format != 'images'
            # possibly pageable
            output(@json_dir, doc)
        end
    else
        output(@json_dir, doc)
    end
end

def process_leaf(leaf, section_doc)
    doc = section_doc.dup
    order = leaf['ORDER'].strip
    doc[:id] = [section_doc[:id], order].join('_')
    #puts "** #{doc[:id]}"
    doc.delete(:description)
    doc.delete(:subject)
    doc.delete(:text)
    doc.delete(:creation_date)
    doc[:top_level] = false

    # object id
    doc[:object_id] = doc[:id].sub(/_\d+$/, '')

    # parent id
    doc[:parent_id] = doc[:id].sub(/_\d+$/, '')

    # position
    doc[:position] = leaf['ORDER'].to_i

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
            unitdate = unitdate.content.strip
            if unitdate =~ /\d\d\d\d/
                doc[:creation_date] = unitdate.sub(/.*(\d\d\d\d).*/, '\1')
                doc[:creation_full_date] = unitdate
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
    if leaf['LABEL'] =~ /\D/
        doc[:title] = [leaf['LABEL'].strip.gsub(/\s*([,.;:!?]+\s*)+$/, '')]
    end

    if dip_path(leaf, /^ReferenceVideo/)
        leaf['TYPE'] = 'video'
    elsif dip_path(leaf, /^ReferenceAudio/)
        leaf['TYPE'] = 'audio'
    end

    case leaf['TYPE']
    when 'audio'
        doc[:object_type] = 'audio'
        doc[:format] = ['audio']
        doc[:reference_audio_url] = dip_url(leaf, /^ReferenceAudio/)
        doc[:secondary_reference_audio_url] = dip_url(leaf, /^SecondaryReferenceAudio/)
    when 'video'
        doc[:object_type] = 'video'
        doc[:format] = ['audiovisual']
        doc[:reference_video_url] = dip_url(leaf, /^ReferenceVideo/)
    when 'photograph'
        doc[:object_type] = 'image'
        doc[:format] = ['images']
        doc[:reference_image_url] = dip_url(leaf, /^ReferenceImage/)
        path = dip_path(leaf, /^ReferenceImage/)
        unless path
            STDERR.puts "bad ref image in #{leaf.to_xml}"
        end
        reference_image_path = File.join(
            @dip_dir,
            'data',
            dip_path(leaf, /^ReferenceImage/),
        )
        begin
            exifr = EXIFR::JPEG.new(reference_image_path)
            doc[:reference_image_width] = exifr.width.to_i
            doc[:reference_image_height] = exifr.height.to_i
        rescue
            STDERR.puts "ERROR: check #{reference_image_path}"
        end

        doc[:thumbnail_url] = dip_url(leaf, /^Thumbnail/)
        doc[:front_thumbnail_url] = dip_url(leaf, /^FrontThumbnail/)
        url = dip_url(leaf, /^PrintImage/)
        if url
            doc[:pdf_url] = url
        end
    else
        if doc.include? :finding_aid_url
            case leaf['TYPE']
            when 'sheet'
                doc[:format] = ['maps']
            else
                doc[:format] = ['archival material']
            end
        end

        doc['object_type'] = 'page'
        doc[:reference_image_url] = dip_url(leaf, /^ReferenceImage/)
        if dip_path(leaf, /^ReferenceImage/).nil?
            STDERR.puts doc[:id] + ' ' + leaf.to_xml
        end
        reference_image_path = File.join(
            @dip_dir,
            'data',
            dip_path(leaf, /^ReferenceImage/),
        )
        begin
            exifr = EXIFR::JPEG.new(reference_image_path)
            doc[:reference_image_width] = exifr.width.to_i
            doc[:reference_image_height] = exifr.height.to_i
        rescue
            STDERR.puts "ERROR: check #{reference_image_path}"
        end

        doc[:thumbnail_url] = dip_url(leaf, /^Thumbnail/)
        doc[:front_thumbnail_url] = dip_url(leaf, /^FrontThumbnail/)
        doc[:pdf_url] = dip_url(leaf, /^PrintImage/)
        text_path = dip_path(leaf, /^Ocr/)
        if text_path
            doc[:text] = IO.read(File.join @dip_dir, 'data', text_path)
        end
        doc[:coordinates] = dip_url(leaf, /^Coordinates/)
    end

    output(@json_dir, doc)

    #puts doc[:id] + ' ' + doc[:format].first
    doc[:format].first
end

def build_core_doc()
    core_doc = {
        id: @id,
        mets_url: [
            'https://nyx.uky.edu/dips',
            @id,
            'data/mets.xml',
        ].join('/'),
    }

    @has_finding_aid = false
    @mets.xpath('//mets:fileGrp', @namespaces).each do |node|
        if node['USE'] and node['USE'].downcase =~ /finding\ aid/
            @has_finding_aid = true
            href = node.xpath('//mets:file[@USE="access"]/mets:FLocat', @namespaces).first['xlink:href']
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
            puts "#{entry}: #{node.content.strip}"
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
    core_doc[:creation_full_date] = core_doc[:date]
    core_doc[:upload_date] = @mets.xpath('//mets:amdSec//mets:versionStatement', @namespaces).first.content.strip

    core_doc
end

#def process_section(json_dir, section)
#    output_section = false
#    section[:object_type] = 'section'
#    section[:top_level] = false
#
#    parents = []
#    n = node.children.first
#
#
#
#    # ...
#
#    if output_section
#        output(json_dir, section)
#    end
#end

def date_recognizer(lis)
    if lis.nil?
        ''
    elsif lis.count > 0
        date = lis.first.dup
        date.gsub!(/\D/, '')
        date[0..3]
    else
        ''
    end
end

def dip_path(node, re)
    fptr = node.xpath('descendant::mets:fptr', @namespaces).select {|n|
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
            elsif value.class == Array
                value.each do |item|
                    unless item.valid_encoding?
                        doc[key] = item.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '').strip.gsub(/\.\.$/, '.')
                    end
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
