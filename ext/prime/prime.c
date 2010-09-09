/************************************************

  prime.c -

  Copyright (C) 2010 Shota Fukumori (sora_h)

************************************************/

#include "ruby/ruby.h"

static VALUE
prime_is_value_prime(int argc, VALUE *argv, VALUE self) {
    int step23;
    long int i,x;
    VALUE value, generator;

    rb_scan_args(argc, argv, "11", &value, &generator);

    if(TYPE(value) == T_FLOAT)
	return Qfalse;

    if(!(FIXNUM_P(value) || TYPE(value) == T_BIGNUM))
	rb_raise(rb_eTypeError, "value must be a numeric");

    x = NUM2LONG(value);

    if(NIL_P(generator)) { /* generator = Prime::Generator23.new */
	step23 = 0;
	i = 1;
	while(i < x){
	    if (step23 < 1) {
		switch(i) {
		    case 1:
		    case 2:
			i++;
			break;
		    case 3:
			i = 5;
			step23 = 2;
			break;
		}
	    }else{
		i += step23;
		step23 = 6 - step23;
	    }

	    if (x % i == 0)
		return Qfalse;
	}
	return Qtrue;
    }else{
	return Qfalse; /* NOTE: fix this */
    }
}

void
Init_prime(void) {
    VALUE rb_cPrime;
    rb_cPrime = rb_define_class("Prime", rb_cObject);

    rb_define_singleton_method(rb_cPrime, "prime?", prime_is_value_prime, -1);
}
