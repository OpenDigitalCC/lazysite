#!/usr/bin/perl
# SM1209: Lazysite::Util::conf_text_value reads one value out of conf text as the
# engine does (resolve_site_vars: ^(\w+)\h*:\h*(.+)$ /mg) - confined to its own
# line, a blank line no occurrence, the last occurrence winning - and the other
# conf readers that used \s* after the colon (the content_root list, the form
# conf keys) stay on their line too.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Util     qw(conf_text_value);
use Lazysite::Handlers ();

my $conf = "app_name: Pocket\napp_scope:\napp_start_url:   \napp_icon_192: /x/f.svg\n"
    . "dup: first\ndup: second\ndup:\nspaced :   padded value  \nlast_key:\n";

is( conf_text_value( $conf, 'app_name' ), 'Pocket', 'a value' );
is( conf_text_value( $conf, 'app_scope' ), undef, 'an empty line is not set - it does NOT read the next line' );
is( conf_text_value( $conf, 'app_start_url' ), '', 'spaces only reads as empty, not as the next line' );
is( conf_text_value( $conf, 'app_icon_192' ), '/x/f.svg', 'the line after an empty one reads its own value' );
is( conf_text_value( $conf, 'missing' ),  undef, 'a missing key' );
is( conf_text_value( $conf, 'last_key' ), undef, 'an empty last line' );
is( conf_text_value( $conf, 'dup' ), 'second', 'a repeated key: the last non-empty occurrence, as the engine reads it' );
is( conf_text_value( $conf, 'spaced' ), 'padded value', 'space before the colon, trimmed value' );
is( conf_text_value( "a: 1\r\nb:\r\nc: 3\r\n", 'b' ), '', 'CRLF: an empty line reads empty (the engine keeps the CR as its value), not the next line' );
is( conf_text_value( "a: 1\r\nb: 2\r\n", 'b' ),   '2',   'CRLF: the value is trimmed' );
is( conf_text_value( $conf,              'app' ), undef, 'a key is whole, not a prefix' );
is( conf_text_value( undef,              'a' ),   undef, 'no text' );

# The same shape in the form conf reader (Lazysite::Handlers): an empty
# spam_keywords line must not read the next line as its keywords.
my $st = Lazysite::Handlers::form_quarantine_state("quarantine:\nspam_keywords:\nspam_url_threshold: 7\nspam_own_domain: on\n");
is( $st->{url_threshold}, 7, 'form conf: the threshold is its own line' )
    or diag explain $st;
ok( $st->{own_domain}, 'form conf: the own domain is its own line' );
is( $st->{keywords}, 0, 'form conf: empty keywords stay empty' ) or diag explain $st;

done_testing;
