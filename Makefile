# Go files tracked by git, expanded lazily by the shell (gopls check needs explicit
# paths - it does not accept ./...). Falls back to find outside a git checkout.
GO_FILES = $$(git ls-files '*.go' 2>/dev/null | xargs -I{} sh -c '[ -f "{}" ] && echo "{}"' || find . -name '*.go' -not -path './vendor/*')

# gopls' new(expr) modernizer needs a go >= 1.26 module and this one declares
# go 1.24.4, so the category cannot fire here at all. The pattern is kept only so
# the lint target reads identically across the proveder Go repos.
GOPLS_EXCLUDE = 'can be simplified to new\(x\)|inlinable wrapper around new\(expr\)'

.PHONY: lint
lint: ## Static analysis: correctness (vet), simplifications (staticcheck), modernizations (gopls)
	@# Every stage runs even if an earlier one reports, so a single invocation shows
	@# the full picture; rc accumulates and the target fails at the end.
	@rc=0; \
	echo "==> go vet (correctness)"; \
	go vet ./... || rc=1; \
	echo "==> staticcheck (simplifications)"; \
	if command -v staticcheck >/dev/null 2>&1; then \
		staticcheck ./... || rc=1; \
	else \
		echo "  skipped: go install honnef.co/go/tools/cmd/staticcheck@latest"; rc=1; \
	fi; \
	echo "==> gopls (modernizations, unused params)"; \
	if command -v gopls >/dev/null 2>&1; then \
		if ! raw="$$(gopls check -severity=hint $(GO_FILES) 2>&1)"; then \
			echo "  gopls failed to run:"; echo "$$raw"; rc=1; \
		fi; \
		out="$$(printf '%s\n' "$$raw" | grep -Ev $(GOPLS_EXCLUDE) || true)"; \
		if [ -n "$$out" ]; then echo "$$out"; rc=1; fi; \
	else \
		echo "  skipped: go install golang.org/x/tools/gopls@latest"; rc=1; \
	fi; \
	$(MAKE) --no-print-directory crap || rc=1; \
	if [ $$rc -eq 0 ]; then echo "lint: clean"; fi; \
	exit $$rc

.PHONY: test
test:
	@echo "executing unit-tests"
	go test -cover -race ./...

.PHONY: audit
audit:
	@echo "go dependencies audit"
	go list -m all | nancy sleuth

.PHONY: audit-fix
audit-fix: ## Attempt to fix vulnerable dependencies automatically
	@echo "updating Go dependencies to latest patch versions"
	go get -u=patch ./...
	go mod tidy
	@echo "re-running dependency audit"
	go list -m all | nancy sleuth

.PHONY: test audit audit-fix lint

# CRAP (Change Risk Anti-Patterns) = cyclomatic complexity² penalized by
# missing test coverage — ranks the functions most dangerous to change.
# The gate fails when any function scores ABOVE CRAP_THRESHOLD. Mocks
# packages are filtered out of the report entirely: test scaffolding
# carries zero coverage by design and would otherwise own its whole top.
# The threshold was set just above the repo's worst score when the gate
# was introduced — treat it as a RATCHET: lower it as the worst functions
# gain tests or shed complexity; never raise it.
CRAP_THRESHOLD ?= 35
# Rows shown in the report table (worst first). Display-only: the
# threshold gate below still scans EVERY row.
CRAP_MAX_ROWS ?= 25

.PHONY: crap
crap:
	@echo "==> crap4go (CRAP: complexity vs coverage, worst first; threshold $(CRAP_THRESHOLD))"; \
	out="$$(go run github.com/unclebob/crap4go/cmd/crap4go@latest)" || { printf '%s\n' "$$out"; exit 1; }; \
	report="$$(printf '%s\n' "$$out" | sed -n '/^CRAP Report/,$$p' | awk 'NR <= 4 || $$2 != "mocks"')"; \
	display="$$(printf '%s\n' "$$report" | awk -v rows=$(CRAP_MAX_ROWS) ' \
		NR <= 4 { print; next } \
		++n <= rows { print; next } \
		END { if (n > rows) printf "... (%d more rows below the top %d)\n", n - rows, rows }')"; \
	printf '%s\n' "$$display"; \
	if [ -n "$$GITHUB_STEP_SUMMARY" ]; then \
		{ echo '### CRAP report (threshold $(CRAP_THRESHOLD), top $(CRAP_MAX_ROWS))'; echo '```'; printf '%s\n' "$$display"; echo '```'; } >> "$$GITHUB_STEP_SUMMARY"; \
	fi; \
	printf '%s\n' "$$report" | awk -v max=$(CRAP_THRESHOLD) ' \
		/^-+$$/ { in_r = 1; next } \
		in_r && NF >= 5 && ($$NF) + 0 > max { bad = 1; print "  over threshold: " $$0 } \
		END { exit bad }' \
	|| { echo "crap: FAILED (score above $(CRAP_THRESHOLD))"; exit 1; }; \
	echo "crap: clean"
