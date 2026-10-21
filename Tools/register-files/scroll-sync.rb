#!/usr/bin/env ruby
# Registers MPScrollSyncMap.{h,m} and its tests in MacDown.xcodeproj.
# Idempotent: re-running after a merge adds only what is missing.
#
# Usage (from anywhere): ruby Tools/register-files/scroll-sync.rb
# Requires the xcodeproj gem (ships with CocoaPods).

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'MacDown.xcodeproj'))

def target_named(project, name)
  project.targets.find { |t| t.name == name } or abort "No target #{name}"
end

def group_containing(project, sibling)
  ref = project.files.find { |f| f.path == sibling }
  abort "Cannot find #{sibling} to locate its group" unless ref
  ref.parent
end

def ensure_file(group, name)
  group.files.find { |f| f.path == name } || group.new_reference(name)
end

def ensure_source(target, ref)
  return if target.source_build_phase.files_references.include?(ref)
  target.source_build_phase.add_file_reference(ref)
end

app = target_named(project, 'MacDown')
tests = target_named(project, 'MacDownTests')

document_group = group_containing(project, 'MPAsset.m')
ensure_file(document_group, 'MPScrollSyncMap.h')
ensure_source(app, ensure_file(document_group, 'MPScrollSyncMap.m'))

tests_group = group_containing(project, 'MPDocumentTests.m')
ensure_source(tests, ensure_file(tests_group, 'MPScrollSyncMapTests.m'))

project.save
puts 'Registered MPScrollSyncMap in MacDown.xcodeproj'
