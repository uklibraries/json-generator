#!/usr/bin/env ruby

require 'exifr'
require 'json'
require 'nokogiri'
require 'parallel'

def dip_path(node, re)
    fptr = node.children.select {|n|
        n['FILEID'] =~ re
    }.first
    if fptr
        file_id = fptr['FILEID']
        flocat = @mets.xpath("//mets:file[@ID='#{file_id}']//mets:FLocat", @namespaces).first
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
#json_dir = '/tmpdir/json-cache/' + xtpath(@id)
mets_file = File.join @dip_dir, 'data', 'mets.xml'

unless File.exist? mets_file
    STDERR.puts "Can't find METS file #{mets_file}"
    exit 1
end

#FileUtils.mkdir_p json_dir

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

@mets.xpath('//mets:div', @namespaces).each do |node|
    case node['TYPE']
    when 'section'
        parents = []
        n = node.children.first
        while n.parent.name == 'div'
            parents.unshift n.parent
            n = n.parent
        end
        id = @id + '_' + parents.collect {|n|
            n['ORDER'].strip
        }.join('_')
        puts "* #{id} - Section"
    else
        parents = []
        n = node.children.first
        while n.parent.name == 'div'
            parents.unshift n.parent
            n = n.parent
        end
        id = @id + '_' + parents.collect {|n|
            n['ORDER'].strip
        }.join('_')

        ref = '- MISSING'
        case node['TYPE']
        when 'audio'
            ref = dip_path(node, /^ReferenceAudio/)
        when 'video'
            ref = dip_path(node, /^ReferenceVideo/)
        when 'photograph'
            ref = dip_path(node, /^ReferenceImage/)
        else
            ref = dip_path(node, /^ReferenceImage/)
        end

        puts "* #{id} #{ref}"
    end
end
