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

    if(x < 2) return Qfalse;

    if(NIL_P(generator)) { /* generator = Prime::Generator23.new */
	step23 = 0;
	i = 1;
	while(i < x) {
	    printf("%ld %d before switch\n", i, step23);
	    if (step23 < 1) {
		switch(i) {
		    case 1:
			printf("case 1\n");
			i = 2;
			printf("%ld %d in switch\n", i, step23);
			break;
		    case 2:
			printf("case 2\n");
			i = 3;
			break;
		    case 3:
			printf("case 3\n");
			i = 5;
			step23 = 2;
			break;
		}
	    }else{
		printf("non! switch!!\n");
		i += step23;
		step23 = 6 - step23;
	    }
	    printf("%ld %d after switch\n", i, step23);

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
