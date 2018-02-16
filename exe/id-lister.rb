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
            @finding_aid_xml.xpath('//xmlns:data[@type="dao"]', @fans).first.content
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
@dip_dir = '/opt/shares/library_dips_1/' + xtpath(@id)

solr_dir = '/tmpdir/solr-prod-cache/' + xtpath(@id)
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

Parallel.each(@mets.xpath('//mets:fileGrp', @namespaces).reject {|node|
    node['USE'] == 'reel metadata' or node['USE'] == 'wave files'
}) do |node|
    puts node.to_xml
end
