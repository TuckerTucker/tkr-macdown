#!/usr/bin/env ruby
# frozen_string_literal: true

# Registers the Wave 3c (local MathJax 3) files in MacDown.xcodeproj.
#
# Idempotent: safe to re-run after a merge; it only adds what is missing and
# reports what it found. Requires the `xcodeproj` gem (ships with CocoaPods).
#
#   ruby Tools/register-files/mathjax.rb
#
# What it ensures:
#   1. Resources/MathJax is a *folder reference* in the MacDown target's
#      Copy Bundle Resources phase, so the vendored es5/ tree is copied into
#      Contents/Resources/MathJax with its directory structure intact.
#   2. MacDownTests/MPMathJaxOfflineTests.m is compiled by MacDownTests.
#   3. MacDownTests links WebKit.framework (the target builds with
#      CLANG_ENABLE_MODULES = NO, so there is no module auto-linking).

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'MacDown.xcodeproj')

project = Xcodeproj::Project.open(PROJECT_PATH)
app = project.targets.find { |t| t.name == 'MacDown' } or abort 'no MacDown target'
tests = project.targets.find { |t| t.name == 'MacDownTests' } or abort 'no MacDownTests target'
changed = false

# 1. MathJax folder reference.
mathjax_refs = project.files.select do |f|
  f.path == 'Resources/MathJax' && f.last_known_file_type == 'folder'
end
abort 'Resources/MathJax folder reference not found' if mathjax_refs.empty?
mathjax = mathjax_refs.first
if app.resources_build_phase.files_references.include?(mathjax)
  puts 'ok: MathJax folder reference is in MacDown Copy Bundle Resources'
else
  app.resources_build_phase.add_file_reference(mathjax, true)
  puts 'added: MathJax folder reference to MacDown Copy Bundle Resources'
  changed = true
end

# 2. Offline MathJax test source.
test_path = 'MPMathJaxOfflineTests.m'
test_group = project.main_group.recursive_children.find do |g|
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) &&
    g.children.any? { |c| c.respond_to?(:path) && c.path == 'MPRendererTests.m' }
end
abort 'group holding MPRendererTests.m not found' unless test_group
test_ref = test_group.files.find { |f| f.path == test_path }
unless test_ref
  test_ref = test_group.new_reference(test_path)
  puts "added: #{test_path} file reference"
  changed = true
end
if tests.source_build_phase.files_references.include?(test_ref)
  puts "ok: #{test_path} is in MacDownTests sources"
else
  tests.source_build_phase.add_file_reference(test_ref, true)
  puts "added: #{test_path} to MacDownTests sources"
  changed = true
end

# 3. WebKit.framework for MacDownTests (reuse the app's file reference).
webkit = project.files.find { |f| f.path == 'System/Library/Frameworks/WebKit.framework' }
abort 'WebKit.framework reference not found' unless webkit
if tests.frameworks_build_phase.files_references.include?(webkit)
  puts 'ok: MacDownTests links WebKit.framework'
else
  tests.frameworks_build_phase.add_file_reference(webkit, true)
  puts 'added: WebKit.framework to MacDownTests'
  changed = true
end

if changed
  project.save
  puts "saved #{PROJECT_PATH}"
else
  puts 'no changes'
end
