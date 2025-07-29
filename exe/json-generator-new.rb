#!/usr/bin/env ruby

require 'fileutils'
require './lib/json-generator.rb'

@id = ARGV[0]
@dip_dir = '/opt/shares/library_dips_2/test_dips/' + xtpath(@id)
@json_dir = '/opt/shares/library_mips_2/exploreuk/json-cache/' + xtpath(@id)
mets_file = File.join @dip_dir, 'data', 'mets.xml'

unless File.exist? mets_file
    STDERR.puts "Can't find METS file #{mets_file}"
    exit 1
end

FileUtils.mkdir_p @json_dir
FileUtils.rm_rf @json_dir
FileUtils.mkdir_p @json_dir

@mets = Nokogiri::XML(IO.read(mets_file))

core_doc = build_core_doc

process_dip_object(core_doc)

first_div = @mets.xpath('//mets:div', @namespaces).first
if first_div.nil?
    exit
end

case first_div['TYPE']
when 'section'
    has_sections = true
else
    has_sections = false
end

if has_sections
    #puts "* sections"
    Parallel.each(@mets.xpath('//mets:div[@TYPE="section"]', @namespaces)) do |section|
    #@mets.xpath('//mets:div[@TYPE="section"]', @namespaces).each do |section|
        process_section(section, core_doc)
        #order = section[:ORDER]
        #puts "* #{core_doc[:id]}_#{order}"
    end
else
    #puts "* no sections"
    Parallel.each(@mets.xpath('//mets:div', @namespaces)) do |leaf|
    #@mets.xpath('//mets:div', @namespaces).each do |leaf|
        process_leaf(leaf, core_doc)
    end
end
