
.PHONY: deploy
deploy:
	hugo
	firebase deploy --only hosting:argvc-blog
