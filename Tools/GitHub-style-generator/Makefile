SASS = node_modules/.bin/sass

target = ../../MacDown/Resources/Styles/GitHub-2020.css

all: $(target)

# The stylesheet is committed, and every MacDown build runs this. Regenerate
# it only when the generator is installed (npm ci), and only ever replace it
# with complete output: a missing or failing sass must never leave an empty
# or partial stylesheet behind. Without the generator, keep the committed
# file and mark it current so the notice is shown once, not every build.
$(target): index.sass package-lock.json
	@if [ ! -x $(SASS) ]; then \
		echo "warning: $(SASS) is not installed; keeping the committed $(notdir $@). Run npm ci in $(CURDIR) to regenerate it."; \
		touch $@; \
		exit 0; \
	fi; \
	$(SASS) --quiet --load-path node_modules $< > $@.sass.tmp \
		&& sed s/.markdown-body/body/ $@.sass.tmp > $@.tmp \
		&& test -s $@.tmp \
		&& mv $@.tmp $@; \
	status=$$?; rm -f $@.sass.tmp $@.tmp; exit $$status

clean:
	$(RM) $(target)

.PHONY: all clean
