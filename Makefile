
components.html: components.md
	markdown -f $@ $<

upload:
	rsync components.html bwarner@people.mozilla.com:public_html/jetpack/components/index.html

webopen:
	open http://people.mozilla.com/~bwarner/jetpack/components/

