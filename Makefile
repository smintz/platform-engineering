all: install
fmt: 
	@echo "Formatting protoconf"
	protoconf fmt -w

build: fmt
	@echo "Building protoconf"
	protoconf compile -process-templates .

install: build
	@echo "Installing workflows"
	
clean:
	@echo "Cleaning protoconf"
	rm -rvf outputs materialized_config .github/workflows/*
