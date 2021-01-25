#!/bin/bash

func_standard () {
	printf "padede\n"
	printf "kapa\n"
}

func_encrypted () {
	printf "enc\n"
	printf "padede\n"
}

read -p "Is this a (r)egular install or (e)ncrypted install? (r/e): " type
case $type in 
        r)
                func_standard
        ;;
        e)
                func_encrypted
        ;;
esac


