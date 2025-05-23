require 'fileutils'

project_path = 'Signal.xcodeproj/project.pbxproj'
file_name = 'AWSConfig.swift'
target_name = 'SignalServiceKit'

pbxproj = File.read(project_path)
matches = pbxproj.scan(/path = ([^;]+);/).flatten

puts "Swift files in project:"
matches.select { |p| p.end_with?('.swift') }.each { |p| puts " - #{p}" }

if matches.any? { |p| p.include?(file_name) }
  puts "\nFound #{file_name} in project file references."
else
  puts "\n#{file_name} is NOT referenced in the project file."
  exit 1
end

# Find the file reference for AWSConfig.swift
file_ref_regex = /([A-Z0-9]+) = {[^}]*path = #{file_name};[^}]*};/
file_ref_match = pbxproj.match(file_ref_regex)
unless file_ref_match
  puts "Could not find file reference for #{file_name}."
  exit 1
end
file_ref = file_ref_match[1]

# Find the build file for AWSConfig.swift
build_file_regex = /([A-Z0-9]+) = {isa = PBXBuildFile; fileRef = #{file_ref};[^}]*};/
build_file_match = pbxproj.match(build_file_regex)
unless build_file_match
  # If not found, create a new build file entry
  build_file_id = (0...24).map { ('A'..'F').to_a.sample + ('0'..'9').to_a.sample }.join
  build_file_entry = "\n    #{build_file_id} = {isa = PBXBuildFile; fileRef = #{file_ref}; };\n"
  pbxproj.sub!(/\/\* Begin PBXBuildFile section \*\//, "\\0#{build_file_entry}")
else
  build_file_id = build_file_match[1]
end

# Find the SignalServiceKit Sources build phase
sources_phase_regex = /([A-Z0-9]+) \/\* Sources \*\/ = {\n\s*isa = PBXSourcesBuildPhase;[^}]*files = \(([^)]*)\);[^}]*};/
pbxproj.scan(sources_phase_regex) do |phase_id, files_block|
  if pbxproj.include?("#{phase_id} /* Sources */") && pbxproj.include?("target = #{target_name};")
    unless files_block.include?(build_file_id)
      # Insert the build file into the files array
      new_files_block = files_block + "\n        #{build_file_id} /* #{file_name} in Sources */, "
      pbxproj.sub!(files_block, new_files_block)
      File.write(project_path, pbxproj)
      puts "Added #{file_name} to #{target_name} target sources."
      exit 0
    else
      puts "#{file_name} is already in #{target_name} target sources."
      exit 0
    end
  end
end

puts "Could not find Sources build phase for #{target_name}."
exit 1