APP_NAME=redgrid
APP_DIR=.
OBJ=$(shell ls $(APP_DIR)/src/*.erl | sed -e 's/\.erl$$/.beam/' | sed -e 's;^$(APP_DIR)/src;$(APP_DIR)/ebin;g') $(shell ls $(APP_DIR)/src/*.app.src | sed -e 's/\.src$$//g' | sed -e 's;^$(APP_DIR)/src;$(APP_DIR)/ebin;g')
DEPS=$(shell cat rebar.config  | sed -e 's;{\(\w\+\), [^,]\+, {\w\+, [^,]\+, \({[^,]\+, [^}]\+}\|".*\?"\)}},\?;\n\0\n;' | sed -e '/{\(\w\+\), [^,]\+, {\w\+, [^,]\+, \({[^,]\+, [^}]\+}\|".*\?"\)}},\?/!d' | sed -e 's;{\(\w\+\), [^,]\+, {\w\+, [^,]\+, \({[^,]\+, [^}]\+}\|".*\?"\)}},\?;deps/\1/rebar.config;')
ERL=erl
PA=$(shell pwd)/$(APP_DIR)/ebin
ERL_LIBS=`pwd`/deps/
REBAR=./rebar

all: $(DEPS) $(OBJ)

echo:
	echo $(DEPS)
clean: FORCE
	$(REBAR) clean
	-rm *.beam erl_crash.dump

$(DEPS):
	$(REBAR) get-deps
	$(REBAR) compile

$(APP_DIR)/ebin/%.app: $(APP_DIR)/src/%.app.src
	$(REBAR) compile

$(APP_DIR)/ebin/%.beam: $(APP_DIR)/src/%.erl
	$(REBAR) compile

shell: all
	ERL_LIBS="$(ERL_LIBS)" $(ERL) -pa $(PA) -config standalone -sname $(APP_NAME)
	[ -f *.beam ] && rm *.beam || true
	[ -f erl_crash.dump ] && rm erl_crash.dump || true

remove_trash:
	-find . -name "*~" -exec rm {} \;.
	-rm *.beam erl_crash.dump
FORCE:
