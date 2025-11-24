.PHONY: help build test publish clean all

GEM_NAME = active_postgres
GEMSPEC = $(GEM_NAME).gemspec
GEM_FILE = $(shell ls -t $(GEM_NAME)-*.gem 2>/dev/null | head -n1)

help:
	@echo "$(GEM_NAME) Release Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build    - Build the gem"
	@echo "  test     - Test gem specification"
	@echo "  publish  - Publish gem to RubyGems.org (interactive)"
	@echo "  clean    - Remove built gem files"
	@echo "  all      - Build, test, and publish (interactive)"
	@echo ""

build:
	@echo "Building $(GEM_NAME)..."
	@rm -f $(GEM_NAME)-*.gem
	@gem build $(GEMSPEC)
	@echo "✓ Built $(GEM_NAME) successfully"

test:
	@echo "Testing $(GEM_NAME) specification..."
	@if [ -z "$(GEM_FILE)" ]; then \
		echo "✗ No gem file found. Run 'make build' first."; \
		exit 1; \
	fi
	@gem specification $(GEM_FILE) > /dev/null
	@echo "✓ Gem specification is valid"

publish:
	@echo "Publishing $(GEM_NAME)..."
	@if [ -z "$(GEM_FILE)" ]; then \
		echo "✗ No gem file found. Run 'make build' first."; \
		exit 1; \
	fi
	@echo "About to push $(GEM_FILE) to RubyGems.org"
	@echo -n "Continue? [y/N] " && read ans && [ $${ans:-N} = y ]
	@gem push $(GEM_FILE)
	@echo "✓ Published $(GEM_NAME) successfully"

clean:
	@echo "Cleaning build artifacts..."
	@rm -f $(GEM_NAME)-*.gem
	@echo "✓ Cleaned $(GEM_NAME)"

all: build test
	@echo ""
	@echo "Build and tests passed. Ready to publish?"
	@echo -n "Publish to RubyGems.org? [y/N] " && read ans && [ $${ans:-N} = y ]
	@$(MAKE) publish
