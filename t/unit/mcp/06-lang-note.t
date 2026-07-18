#!/usr/bin/perl
# SM179 P7: when the instance is a language set, the MCP initialize instructions
# gain a paragraph telling the agent the invariant (sibling roots mirror the
# source), the rule (translate values, never keys/paths), the pointer
# (lang-status) and the prohibition (don't hand-build switchers/hreflang). A
# monolingual instance's instructions are unchanged.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";

sub init_instructions {
    my ($conf) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/manager/locks", "$d/lazysite/auth" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf $conf;
    close $cf;

    my $body = encode_json(
        { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = 'POST';
    $ENV{CONTENT_LENGTH} = length $body;
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $obj = eval { decode_json( $jb // '' ) };
    return $obj->{result}{instructions} // '';
}

# --- a language set: the note is present --------------------------------------
my $set_conf = <<'CONF';
site_name: T
lang: en
lang_group: providers
content_root: sites/en
alias_hosts: de.example
alias.de.example.lang: de
alias.de.example.lang_group: providers
alias.de.example.content_root: sites/de
CONF
my $with = init_instructions($set_conf);
like( $with, qr/LANGUAGE SET/,          'set: the language-set paragraph is present' );
like( $with, qr/group providers/,       'set: names the group' );
like( $with, qr/identical path/i,       'set: states the mirror-at-same-path rule' );
like( $with, qr/lang-status/,           'set: points at lang-status' );
like( $with, qr/never.*keys.*paths|keys, paths/i, 'set: forbids translating keys/paths' );
like( $with, qr/hand-build a language switcher|switcher or hreflang/i,
    'set: forbids hand-building switchers/hreflang' );

# --- a monolingual instance: no note ------------------------------------------
my $mono = init_instructions("site_name: T\nlang: en\n");
like( $mono,   qr/maintenance agent/, 'mono: base instructions still present' );
unlike( $mono, qr/LANGUAGE SET/,      'mono: no language-set paragraph' );

# --- a lone lang_group with no sibling is not a set ---------------------------
my $lone = init_instructions("site_name: T\nlang: en\nlang_group: providers\n");
unlike( $lone, qr/LANGUAGE SET/, 'a single member is not a set - no note' );

done_testing;
