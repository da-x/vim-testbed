.PHONY: build push test

TAG:=10

build:
	docker build -t alonid/vim-testbed:$(TAG) .

push:
	docker push alonid/vim-testbed:$(TAG)

update_latest:
	docker tag alonid/vim-testbed:$(TAG) alonid/vim-testbed:latest
	docker push alonid/vim-testbed:latest

# test: build the base image and example image on top, running tests therein.
DOCKER_BASE_IMAGE:=vim-testbed-base
test:
	docker build -t "$(DOCKER_BASE_IMAGE)" .
	make -C example test
