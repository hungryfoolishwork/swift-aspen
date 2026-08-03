.PHONY: party identity identitychain

party:
	swift build --product party

identity:
	swift build --product identity

identitychain:
	swift build --product identitychain
