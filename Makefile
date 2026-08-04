.PHONY: party pool identity identitychain

party:
	swift build --product party

pool:
	swift build --product pool

identity:
	swift build --product identity

identitychain:
	swift build --product identitychain
