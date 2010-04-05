
all: components.html confinement.html index.html

%.html: %.md
	markdown -f $@ $<

#components.html: components.md
#	markdown -f $@ $<

upload:
	rsync *.html *.png bwarner@people.mozilla.com:public_html/jetpack/components/

webopen:
	open http://people.mozilla.com/~bwarner/jetpack/components/

