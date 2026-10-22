#!/usr/bin/env ruby
# Registers the Wave 3c word-count files in MacDown.xcodeproj.
#
# Idempotent: re-running it after a merge adds only what is missing.
#
#   ruby Tools/register-files/text-count.rb
#
# * MacDown/Code/Utility/MPPreviewTextCount.{h,m} -> MacDown target sources
# * MacDown/Resources/Scripts (folder reference)   -> MacDown target resources,
#   so text-count.js lands at Contents/Resources/Scripts/text-count.js
# * MacDownTests/MPPreviewTextCountTests.m          -> MacDownTests sources
# * MacDownTests/Fixtures/text-count-fixture.html   -> MacDownTests resources
#
# Requires the xcodeproj gem (ships with CocoaPods).

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'MacDown.xcodeproj'))

def target_named(project, name)
  project.targets.find { |t| t.name == name } or abort "No target #{name}"
end

def group_with_real_path(project, real_path)
  project.main_group.recursive_children.find do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXGroup) &&
      !c.path.to_s.empty? && c.real_path.to_s == real_path
  end or abort "No group for #{real_path}"
end

def file_in(group, path)
  group.files.find { |f| f.path == path } || group.new_reference(path)
end

def add_source(target, ref)
  return if target.source_build_phase.files_references.include?(ref)
  target.source_build_phase.add_file_reference(ref)
end

def add_resource(target, ref)
  return if target.resources_build_phase.files_references.include?(ref)
  target.resources_build_phase.add_file_reference(ref)
end

app = target_named(project, 'MacDown')
tests = target_named(project, 'MacDownTests')

utility = group_with_real_path(project, File.join(ROOT, 'MacDown/Code/Utility'))
file_in(utility, 'MPPreviewTextCount.h')
add_source(app, file_in(utility, 'MPPreviewTextCount.m'))

# The Scripts folder reference sits next to the MathJax folder reference,
# which is how MacDown already ships directory-shaped resources.
mathjax = project.objects.find do |o|
  o.is_a?(Xcodeproj::Project::Object::PBXFileReference) &&
    o.path == 'Resources/MathJax'
end or abort 'No MathJax folder reference to anchor Scripts next to'
resources_group = mathjax.parent
scripts = resources_group.files.find { |f| f.path == 'Resources/Scripts' }
unless scripts
  scripts = resources_group.new_reference('Resources/Scripts')
  scripts.name = 'Scripts'
  scripts.last_known_file_type = 'folder'
end
add_resource(app, scripts)

tests_group = group_with_real_path(project, File.join(ROOT, 'MacDownTests'))
add_source(tests, file_in(tests_group, 'MPPreviewTextCountTests.m'))
fixture = tests_group.files.find do |f|
  f.path == 'Fixtures/text-count-fixture.html'
end
unless fixture
  fixture = tests_group.new_reference('Fixtures/text-count-fixture.html')
  fixture.name = 'text-count-fixture.html'
  fixture.last_known_file_type = 'text.html'
end
add_resource(tests, fixture)

# The tests instantiate WKWebView (and, until WebKitLegacy is removed, the
# legacy WebView), so the test bundle links WebKit itself rather than relying
# on the host app's symbols.
webkit = project.frameworks_group.recursive_children.find do |f|
  f.is_a?(Xcodeproj::Project::Object::PBXFileReference) &&
    f.path == 'System/Library/Frameworks/WebKit.framework'
end or abort 'No WebKit.framework reference'
unless tests.frameworks_build_phase.files_references.include?(webkit)
  tests.frameworks_build_phase.add_file_reference(webkit)
end

project.save
puts 'Registered Wave 3c text-count files.'
