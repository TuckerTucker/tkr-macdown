#!/usr/bin/env ruby
# Registers MPPreviewNavigationPolicy.{h,m} and its tests in
# MacDown.xcodeproj, and links UniformTypeIdentifiers.framework into the app.
# Idempotent: re-running after a merge adds only what is missing.
#
# Usage (from anywhere): ruby Tools/register-files/navigation-policy.rb
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
ensure_file(document_group, 'MPPreviewNavigationPolicy.h')
ensure_source(app, ensure_file(document_group, 'MPPreviewNavigationPolicy.m'))

tests_group = group_containing(project, 'MPDocumentTests.m')
ensure_source(tests,
              ensure_file(tests_group, 'MPPreviewNavigationPolicyTests.m'))

# Added by hand rather than with add_system_framework, which pins the path
# to a versioned SDK under DEVELOPER_DIR. This matches WebKit.framework's
# existing SDKROOT-relative reference.
framework_path = 'System/Library/Frameworks/UniformTypeIdentifiers.framework'
framework = project.frameworks_group.files.find { |f| f.path == framework_path }
unless framework
  framework = project.frameworks_group.new_reference(framework_path, :sdk_root)
  framework.name = File.basename(framework_path)
end
unless app.frameworks_build_phase.files_references.include?(framework)
  app.frameworks_build_phase.add_file_reference(framework)
end

project.save
puts 'Registered MPPreviewNavigationPolicy in MacDown.xcodeproj'
