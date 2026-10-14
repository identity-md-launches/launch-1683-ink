.PHONY: check abi

check:
	forge build
	forge test
	forge fmt --check
	python3 -m unittest discover -s tools -p 'test_*.py' -v

abi:
	forge build
	python3 tools/export_abis.py
