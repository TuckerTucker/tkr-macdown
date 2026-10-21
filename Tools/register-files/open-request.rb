#!/usr/bin/env ruby
# Registers MPOpenRequest.{h,m} and MPErrorPresenting.{h,m} in
# MacDown.xcodeproj. Idempotent: re-running after a merge adds only what is
# missing.
#
# Usage (from anywhere): ruby Tools/register-files/open-request.rb
# Requires the xcodeproj gem (ships with CocoaPods).

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'MacDown.xcodeproj'))

def target_named(project, name)
  project.targets.find { |t| t.name == name } or abort "No target #{name}"
end

# Returns the group holding sibling and the directory prefix its files use.
def group_containing(project, sibling)
  ref = project.files.find { |f| File.basename(f.path.to_s) == sibling }
  abort "Cannot find #{sibling} to locate its group" unless ref
  [ref.parent, File.dirname(ref.path)]
end

def ensure_file(group, prefix, name)
  path = prefix == '.' ? name : File.join(prefix, name)
  group.files.find { |f| f.path == path } ||
    group.new_reference(path).tap { |ref| ref.name = name }
end

def ensure_source(target, ref)
  return if target.source_build_phase.files_references.include?(ref)
  target.source_build_phase.add_file_reference(ref)
end

app = target_named(project, 'MacDown')

group, prefix = group_containing(project, 'MPMainController.m')
ensure_file(group, prefix, 'MPOpenRequest.h')
ensure_source(app, ensure_file(group, prefix, 'MPOpenRequest.m'))

group, prefix = group_containing(project, 'MPUtilities.m')
ensure_file(group, prefix, 'MPErrorPresenting.h')
ensure_source(app, ensure_file(group, prefix, 'MPErrorPresenting.m'))

project.save
puts 'Registered MPOpenRequest and MPErrorPresenting in MacDown.xcodeproj'
