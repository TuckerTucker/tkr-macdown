# Registers the WKWebView preview host sources and removes the WebKitLegacy
# helpers they replace. Idempotent: safe to re-run after merges.
require 'xcodeproj'

project = Xcodeproj::Project.open(File.expand_path('../../MacDown.xcodeproj', __dir__))
app = project.targets.find { |t| t.name == 'MacDown' }
document_group = project.files.find { |f| f.path.to_s.end_with?('MPDocument.m') }.parent

%w[MPPreviewSchemeHandler MPPreviewBridge].each do |name|
  %w[h m].each do |ext|
    path = "#{name}.#{ext}"
    ref = document_group.files.find { |f| f.path == path } || document_group.new_file(path)
    app.add_file_references([ref]) if ext == 'm' && !app.source_build_phase.files_references.include?(ref)
  end
end

tests = project.targets.find { |t| t.name == 'MacDownTests' }
test_group = project.files.find { |f| f.path.to_s.end_with?('MPDocumentTests.m') }.parent
test_ref = test_group.files.find { |f| f.path == 'MPPreviewHostTests.m' } || test_group.new_file('MPPreviewHostTests.m')
tests.add_file_references([test_ref]) unless tests.source_build_phase.files_references.include?(test_ref)

removed = %w[MPMathJaxListener.h MPMathJaxListener.m DOMNode+Text.h DOMNode+Text.m WebView+WebViewPrivateHeaders.h]
project.files.select { |f| removed.include?(File.basename(f.path.to_s)) }.each do |ref|
  ref.build_files.each(&:remove_from_project)
  ref.remove_from_project
end

project.save
puts 'registered preview host files'
