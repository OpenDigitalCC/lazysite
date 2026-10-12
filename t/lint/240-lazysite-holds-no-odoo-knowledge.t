#!/usr/bin/perl
# SM747: LAZYSITE HOLDS NO ODOO KNOWLEDGE.
#
# The rule that keeps the Odoo extension a facility rather than a connector
# (SM747, *The rule that keeps it general-purpose*, 2026-10-01): model names,
# field names, domains, the RPC call shapes and the ERP's semantics live in
# OOM's operation packs. Lazysite names an operation, binds its parameters,
# renders the descriptors it is handed and presents a plan. An app that needs
# invoices then needs an operation pack, not engine work.
#
# The filing says the rule is CHECKABLE and that the gate lands with the first
# code. This is it. It reads every functional file - the CGIs, the processor's
# parts, the library, the plugins, the tools and the shipped scripts - with
# comments and POD removed, so prose explaining the boundary may name what it
# keeps out, and code may not.
#
# WHAT COUNTS AS ODOO KNOWLEDGE, each a class rather than a list of today's
# offenders:
#
#   * the RPC surface - execute_kw, call_kw, the /jsonrpc, /xmlrpc and /web/
#     endpoint paths, and the ORM method names a caller would have to know to
#     build a call;
#   * a dotted Odoo model name in a string (res.partner, sale.order, ...), by
#     the module prefixes Odoo ships;
#   * Odoo's field types (many2one, monetary, ...) - the type MAPPING is Q3's
#     and sits with OOM: lazysite takes a portable type from the descriptor or
#     refuses the field;
#   * Odoo's exception classes.
#
# Tests are out of scope: a test pack may name the fake models its fake Odoo
# serves, and that is fixture, not engine.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @files = sort( glob("$root/*.pl"), glob("$root/lazysite-processor/*.pm"),
    glob("$root/plugins/*.pl"), glob("$root/tools/*.pl"), glob("$root/tools/*.sh"),
    _pm_under("$root/lib"),     glob("$root/starter/assets/*.js") );
cmp_ok( scalar @files, '>', 50, 'the functional files were found' );

# `mail.` is left out: lazysite's own config keys use it (`mail.per_hour`), and
# a rule that fires on a site setting teaches people to read past it.
my $PREFIX = join '|', qw(res crm sale account stock product ir hr project purchase
    mrp website pos helpdesk calendar uom utm survey event fleet);
my @RULES = (
    [ 'an RPC method or endpoint', qr{\b(?:execute_kw|call_kw)\b|/(?:jsonrpc|xmlrpc)\b|/web/(?:session|dataset)\b} ],
    [ 'an ORM method name', qr{\b(?:search_read|search_count|read_group|fields_get|name_search|name_get)\b} ],
    [ 'an Odoo model name', qr{['"](?:$PREFIX)\.[a-z][a-z_]*(?:\.[a-z_]+)*['"]} ],
    [ 'an Odoo field type', qr{\b(?:many2one|one2many|many2many|many2one_reference|monetary)\b} ],
    [ 'an Odoo exception class', qr{\bodoo\.(?:exceptions|http)\b} ],
);

my @hits;
for my $f (@files) {
    open my $fh, '<', $f or next;
    my ( $pod, $js ) = ( 0, $f =~ /\.js\z/ );
    my $n = 0;
    while ( my $l = <$fh> ) {
        $n++;
        last if $l =~ /\A__(?:END|DATA)__\b/;
        if ( !$js && $l =~ /\A=(\w+)/ ) { $pod = $1 ne 'cut'; next }
        next if $pod;
        next if $l =~ /\A\s*#/ || ( $js && $l =~ m{\A\s*(?://|/?\*)} );
        ( my $code = $l ) =~ s/\s+#\s.*\z//s unless $js;
        $code //= $l;
        for my $r (@RULES) {
            next unless $code =~ $r->[1];
            ( my $rel = $f )  =~ s{\A\Q$root\E/}{};
            push @hits, "$rel:$n: $r->[0]: " . substr( $code =~ s/\A\s+|\s+\z//gr, 0, 120 );
        }
    }
    close $fh;
}

is( scalar @hits, 0, 'no functional file carries Odoo knowledge' )
    or diag( join( "\n", @hits )
        . "\n\nThis belongs in an OOM operation pack. Lazysite names an operation, binds its "
        . "parameters and renders what it is handed (SM747, the rule that keeps it "
        . "general-purpose)." );

sub _pm_under {
    my ($dir) = @_;
    my @out;
    opendir my $dh, $dir or return;
    for my $e ( sort readdir $dh ) {
        next if $e =~ /\A\./;
        my $p = "$dir/$e";
        if    ( -d $p )          { push @out, _pm_under($p) }
        elsif ( $e =~ /\.pm\z/ ) { push @out, $p }
    }
    closedir $dh;
    return @out;
}

done_testing();
