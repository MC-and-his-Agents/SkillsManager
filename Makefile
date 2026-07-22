.PHONY: lint

lint:
	python3 -m json.tool .loom/installed-state.json >/dev/null
	bash -n Scripts/*.sh
