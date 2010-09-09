/************************************************

  prime.c -

  Copyright (C) 2010 Shota Fukumori (sora_h)

************************************************/

#include "ruby/ruby.h"

VALUE prime_um_value;

static VALUE
prime_is_value_prime(int argc, VALUE *argv, VALUE self) {
    int step23, v;
    long int i, x;
    VALUE value, generator, t, iv;

    rb_scan_args(argc, argv, "11", &value, &generator);

    if(TYPE(value) == T_FLOAT)
	return Qfalse;

    if(!(FIXNUM_P(value) || TYPE(value) == T_BIGNUM))
	rb_raise(rb_eTypeError, "value must be a numeric");
    if(!prime_um_value)
	prime_um_value = ULONG2NUM(ULONG_MAX);

    if (!FIXNUM_P(value) && rb_funcall(value,rb_intern(">"),1,prime_um_value) == Qtrue){
	v = 1;
	if (rb_funcall(value,rb_intern("<"),1,INT2FIX(2)) == Qtrue)
	    return Qfalse;
	if (rb_funcall(value,rb_intern("=="),1,INT2FIX(2)) == Qtrue ||
	    rb_funcall(value,rb_intern("=="),1,INT2FIX(3)) == Qtrue)
	    return Qtrue;
    } else {
	v = 0;
	x = NUM2LONG(value);
	if (x < 0)  x = x * -1;

	if (x <  2) return Qfalse;
	if (x == 2) return Qtrue;
	if (x == 3) return Qtrue;
    }
    if(NIL_P(generator)) { /* generator = Prime::Generator23.new */
	step23 = 0;
	i = 1;
	while(1) {
	    if (step23 < 1) {
		switch(i) {
		    case 1:
			i = 2;
			break;
		    case 2:
			i = 3;
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
	    if (v) {
		iv = ULONG2NUM(i);
		t = rb_funcall(value,rb_intern("divmod"),1,iv);
		if (rb_funcall(rb_ary_shift(t),rb_intern("<"),1,iv) == Qtrue)
		    return Qtrue;
		if (rb_funcall(rb_ary_shift(t),rb_intern("=="),1,INT2FIX(0)) == Qtrue)
		    return Qfalse;
	    } else {
		if (x / i < i)
		    return Qtrue;
		if (x % i == 0)
		    return Qfalse;
	    }
	}
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
