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
@aip = ARGV[1]
@dip_dir = '/opt/shares/library_dips_2/test_dips/' + xtpath(@id)
@aip_dir = '/opt/shares/library_aips_1/' + xtpath(@aip)
#json_dir = '/tmpdir/json-cache/' + xtpath(@id)
mets_file = File.join @dip_dir, 'data', 'mets.xml'
mets_bak_file = File.join @dip_dir, 'data', 'mets.bak.xml'

unless File.exist? mets_file
    STDERR.puts "Can't find DIP METS file #{mets_file}"
    exit 1
end

aip_mets_file = File.join @aip_dir, 'data', 'mets.xml'

unless File.exist? aip_mets_file
    STDERR.puts "Can't find AIP METS file #{aip_mets_file}"
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
@aip_mets = Nokogiri::XML(IO.read(aip_mets_file))

# align fileSec
@mets.xpath('//mets:fileGrp', @namespaces).each do |node|
    if node.xpath('mets:file').count == 0
        STDERR.puts "* #{node['ID']}"
        exit 1
    end
end

# align structMap sections
prev = nil
updated = false
@mets.xpath('//mets:div[@TYPE="section"]', @namespaces).each do |node|
    if (node.xpath('mets:fptr').count == 0) and (node.xpath('mets:div').count == 0)

        # get identifiers
        prev_count = prev.xpath('mets:div/mets:fptr[contains(@FILEID, "FrontThumbnailFile")]').count
        if prev_count == 0
            STDERR.puts "can't find front thumbnail in #{@id} #{prev.to_xml}"
            exit 1
        end

        prev_id = prev.xpath('mets:div/mets:fptr[contains(@FILEID, "FrontThumbnailFile")]').first['FILEID'].sub(/^FrontThumbnailFile/, '')

        cur_id = prev.xpath('mets:div/mets:fptr[contains(@FILEID, "FrontThumbnailFile")]').last['FILEID'].sub(/^FrontThumbnailFile/, '')

        if cur_id == prev_id
            STDERR.puts "ids match ( #{cur_id} ) - I can't fix this"
            exit 1
        end

        if @aip_mets.xpath("//mets:fptr[@FILEID='MasterFile#{cur_id}']").count == 0
            STDERR.puts "no match in AIP for #{cur_id} - I can't fix this"
            exit 1
        end

        updated = true
        puts "fixing #{@id} #{cur_id}"

        aip_cur_div = @aip_mets.xpath("//mets:fptr[@FILEID='MasterFile#{cur_id}']").first.parent

        div = Nokogiri::XML::Node.new 'div', @mets
        div['TYPE'] = aip_cur_div['TYPE']
        div['LABEL'] = aip_cur_div['LABEL']
        div['ORDER'] = aip_cur_div['ORDER']


        prev.xpath("mets:div/mets:fptr[contains(@FILEID, '#{cur_id}')]").each do |fptr|
            div.add_child(fptr.dup)
            fptr.remove
        end

        node.add_child(div.dup)
    end
    prev = node
end

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
