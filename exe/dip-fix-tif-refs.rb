#!/usr/bin/env ruby

require 'digest'
require 'exifr'
require 'fileutils'
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
mets_bak_file = File.join @dip_dir, 'data', 'mets.bak.xml'

unless File.exist? mets_file
    STDERR.puts "Can't find DIP METS file #{mets_file}"
    exit 1
end

@namespaces = {
    'dc' => "http://purl.org/dc/elements/1.1/",
    'mets' => "http://www.loc.gov/METS/",
}

@fans = {
    'xmlns' => "urn:isbn:1-931666-22-9",
}

@mets = Nokogiri::XML(IO.read(mets_file))

# align fileSec
@mets.xpath('//mets:fileGrp', @namespaces).each do |node|
    if node.xpath('mets:file').count == 0
        STDERR.puts "* #{node['ID']}"
        exit 1
    end
end

wanted_files = [
    {
        use: "thumbnail",
        label: "Thumbnail",
        extension: "_tb.jpg",
        mime: "image/jpeg",
    },
    {
        use: "front thumbnail",
        label: "FrontThumbnail",
        extension: "_ftb.jpg",
        mime: "image/jpeg",
    },
    {
        use: "reference image",
        label: "ReferenceImage",
        extension: ".jpg",
        mime: "image/jpeg",
    },
    {
        use: "print image",
        label: "PrintImage",
        extension: ".pdf",
        mime: "image/jpeg",
    },
]

prev = nil
updated = false

# take care of doubles
ids = @mets.xpath('//mets:file[contains(@ID, "MasterFile")]').collect {|n| 
    n['ID'].sub(/MasterFile/, '')
}.sort.uniq

ids.each do |id|
    nodes = @mets.xpath("//mets:file[@ID='MasterFile#{id}']")
    if nodes.count > 1
        updated = true
        nodes.each_with_index do |node, index|
            new_id = id + 'dupe' + index.to_s
            node['ID'] = 'MasterFile' + new_id
            node.parent['ID'] = 'FileGrp' + new_id
        end
        nodes = @mets.xpath("//mets:fptr[@FILEID='MasterFile#{id}']")
        nodes.each_with_index do |node, index|
            new_id = id + 'dupe' + index.to_s
            node['FILEID'] = 'MasterFile' + new_id
        end
    end
end

@mets.xpath('//mets:file[contains(@ID, "MasterFile")]').each do |node|
    updated = true
    id = node['ID'].sub(/MasterFile/, '')
    orig_flocat = node.xpath('mets:FLocat').first
    filename = orig_flocat['xlink:href'].sub(/\.tif$/, '')
    basename = File.basename(filename)

    fileGrp = node.parent
    wanted_files.each do |wanted_file|
        #div = Nokogiri::XML::Node.new 'div', @mets
        file = Nokogiri::XML::Node.new 'file', @mets
        file['ID'] = wanted_file[:label] + id
        file['USE'] = wanted_file[:use]
        file['MIMETYPE'] = wanted_file[:mime]
        fileGrp.add_child(file)

        flocat = Nokogiri::XML::Node.new 'FLocat', @mets
        flocat['LOCTYPE'] = 'OTHER'
        flocat['xlink:href'] = File.join(
            filename,
            basename + wanted_file[:extension]
        )
        file.add_child(flocat)
    end
    node.remove
end

@mets.xpath('//mets:fptr[contains(@FILEID, "MasterFile")]').each do |node|
    updated = true
    id = node['FILEID'].sub(/MasterFile/, '')
    div = node.parent
    wanted_files.each do |wanted_file|
        fptr = Nokogiri::XML::Node.new 'fptr', @mets
        fptr['FILEID'] = wanted_file[:label] + id
        div.add_child(fptr)
    end
    node.remove
end

#puts "test run, check mets.bak.xml"
#File.open(mets_bak_file, 'w') do |f|
#    f.write(@mets.to_xml)
#end
#exit

if updated
    puts "fixing bag  #{@id}"
    File.open(mets_bak_file, 'w') do |f|
        f.write(@mets.to_xml)
    end

    Dir.chdir(@dip_dir)
    mets_file = File.join('data', 'mets.xml')
    mets_bak_file = File.join('data', 'mets.bak.xml')

    FileUtils.mv mets_bak_file, mets_file

    alg_for = {
        'md5' => Digest::MD5,
        'sha1' => Digest::SHA1,
        'sha256' => Digest::SHA256,
    }

    algs = alg_for.keys

    algs.each do |alg|
        original = "manifest-#{alg}.txt"
        if File.file?(original)
            revised = "new-#{original}"
            File.open(revised, 'w') do |f|
                File.readlines(original).each do |line|
                    checksum, file = line.split(/\s+/)
                    if file == mets_file
                        new_checksum = alg_for[alg].file mets_file
                        f.puts "#{new_checksum.hexdigest} #{mets_file}"
                    else
                        f.puts line
                    end
                end
            end
            FileUtils.rm original
            FileUtils.mv revised, original
        end
    end

    algs.each do |alg|
        original = "tagmanifest-#{alg}.txt"
        if File.file?(original)
            revised = "new-#{original}"
            File.open(revised, 'w') do |f|
                File.readlines(original).each do |line|
                    checksum, file = line.split(/\s+/)
                    if file =~ /manifest/
                        new_checksum = alg_for[alg].file file
                        f.puts "#{new_checksum.hexdigest} #{file}"
                    else
                        f.puts line
                    end
                end
            end
            FileUtils.rm original
            FileUtils.mv revised, original
        end
    end
end
