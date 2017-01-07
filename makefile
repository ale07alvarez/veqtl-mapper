LDC = ldc
DMD = dmd

DSOURCES = src/main.d src/arg_parse.d src/read_data.d src/calculation.d src/run_analysis.d

ldc : ${DSOURCES} src/beta.o views/commit
	${LDC} -release -enable-inlining -O -w -oq -Jviews ${DSOURCES} src/beta.o -of="bin/VEQM"
	rm -f bin/*.o src/*.o *.o

test : ${DSOURCES} src/beta.o
	${LDC} -d-debug -g -unittest -w -Jviews ${DSOURCES} src/beta.o -of="unittest"
	./unittest
	rm -f bin/*.o unittest src/*.o *.o

dmd : ${DSOURCES} src/beta.o
	${DMD} -O -release -noboundscheck -inline -Jviews ${DSOURCES} src/beta.o -ofbin/VEQM
	rm -f bin/*.o src/*.o *.o

dmd_test : ${DSOURCES} src/beta.o
	${DMD} -debug -g -unittest -w -Jviews ${DSOURCES} src/beta.o -ofunittest
	./unittest
	rm -f bin/*.o unittest src/*.o *.o

views/commit : ${DSOURCES} src/beta.c
	mkdir -p views
	git rev-parse --short HEAD > views/commit

.PHONY : test ldc dmd dmd_test clean install

clean :
	rm -f bin/*.o src/*.o *.o bin/VEQM

install : ${DSOURCES} VEQM.1
	cp -v $(shell pwd)/bin/VEQM /usr/local/bin/
	cp -v $(shell pwd)/VEQM.1 /usr/local/man/man1/