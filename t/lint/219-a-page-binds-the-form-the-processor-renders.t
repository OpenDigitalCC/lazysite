#!/usr/bin/perl
# SM976 Q15f (ruled 2026-10-09, "One reading, processor's"): which form a page
# binds has one answer everywhere.
#
# The processor renders a page's form from its own front-matter parse
# (lazysite-processor/front-matter.pm, parse_yaml_front_matter). The manager's
# form rule (form_bindings, the write rule, create_form, the validators) cannot
# load the processor, so Lazysite::Manager::Common::page_form is a MARKED COPY of
# that reading (ADR 0001's convention for a copy: allowed, marked, pinned). This
# is the pin.
#
# Before Q15f the walker read the first plain `form: NAME` line within 16 KB, and
# a page in another domain with `form:` and the name on the next line rendered
# and received the form `contact` while the walker saw nothing - so a caller
# scoped to a domain that also bound `contact` reached the other site's
# submissions (tmp/q15e-walker-probe.out).
#
# ASSERTED BY RUNNING BOTH ON THE SAME TEXTS, as t/lint/125 and 129 do - never by
# comparing source. Three ways: the strings themselves; the same texts written
# to a site and read back, the processor through its own read_file and the
# manager through form_bindings' walk; and a seeded generator of front matter
# from the fragments a hand-rolled parser gets wrong.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(load_processor setup_minimal_site site_tempdir);
use Lazysite::Manager::Common ();

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

# The processor holds a page as its read_file returns it: through the :utf8
# layer, so always a character string. A literal here is upgraded to match.
sub proc_form {
    my $t = $_[0];
    utf8::upgrade($t);
    my ($meta) = main::parse_yaml_front_matter($t);
    return $meta->{form};
}
sub lib_form { return Lazysite::Manager::Common::page_form( $_[0] ) }

my @TEXTS = (
    "---\nform: leads\n---\n",
    "---\nform: \"leads\"\n---\n",
    "---\nform: 'Leads'\n---\n",
    "---\nform:\n  leads\n---\n",                 # the value on the next line, indented: YAML continuation
    "---\nform:\n\n  leads\n---\n",               # past a blank line
    "---\nform: decoy\nform: leads\n---\n",       # the last key wins
    "---\nform: leads\nform: ''\n---\n",          # ...even when it is empty
    "---\nform: le.ads\n---\n",                   # the sanitiser drops the dot
    "---\nform: leads # a comment\n---\n",        # and the comment's spaces
    "---\nform: a b\n---\n",
    "---\nform: [% x %]leads\n---\n",             # TT markers stripped
    "---\nform: [%%]\n---\n",
    "---\ntitle: T\r\nform: leads\r\n---\r\n",    # CRLF
    "---   \nform: leads  \n---  \n",             # trailing blanks on the fences
    "---\n\n\nform: leads\n---\n",                # blank lines after the fence
    "---\nform :\tleads\n---\n",
    "---\ntitle:\nform: leads\n---\n",            # SM1213: an empty value is none; the next key is read
    "---\nfoo: \nform: leads\n---\n",
    "---\nform: leads\n---",                      # no newline after the closing fence
    "---\nform: leads\n---\nbody\n",
    "---\n  form: leads\n---\n",                  # indented
    "---\nForm: leads\n---\n",
    "---\nformx: leads\n---\n",
    "---\ntags:\n  - a\nform: leads\n---\n",
    "---\nregister: [sitemap.xml]\nform: leads\n---\n",
    "---\nsections:\n  - type: x\n    form: inner\nform: leads\n---\n",
    "---\nsections:\n  - type: x\n    form: inner\n---\n",
    "---\ntt_page_var:\n  form: inner\n---\n",
    "---\ntitle: T\n---\nform: leads\n",          # a body line
    "# no front matter\nform: leads\n",
    "\x{FEFF}---\nform: leads\n---\n",            # a byte-order mark
    "---\x{A0}\nform: leads\n---\n",              # a no-break space on the fence
    "---\nform:\x{A0}leads\n---\n",
    "---\ntitre\x{E9}:\nform: leads\n---\n",      # a non-ASCII key, empty: the next key is read
    "---\nform: l\x{E9}ads\n---\n",
    "---\nform:\n---\n",
    "---\nform: \"\"\n---\n",
    "---\n" . ( "x: " . ( 'y' x 80 ) . "\n" ) x 300 . "form: leads\n---\n",   # past 16 KB
    "",
);

subtest 'the marked copy reads every text as the processor does' => sub {
    for my $t (@TEXTS) {
        ( my $label = substr( $t, 0, 60 ) ) =~ s/([^\x20-\x7e])/sprintf( q(\x{%X}), ord $1 )/ge;
        is( lib_form($t), proc_form($t), "page_form = the processor's form for: $label" );
    }
};

# The same, through the files: the processor reads with its read_file, the walk
# with its own reader, and each page's form is where form_bindings files it.
subtest 'form_bindings files each page under the form the processor renders' => sub {
    make_path("$d/q15f");
    my %want;
    for my $i ( 0 .. $#TEXTS ) {
        my $p = "$d/q15f/p$i.md";
        open my $fh, '>:utf8', $p or die "$p: $!";
        print {$fh} $TEXTS[$i];
        close $fh;
        my $f = proc_form( main::read_file($p) );
        $want{"q15f/p$i.md"} = defined $f ? lc $f : '';
    }
    local $Lazysite::Manager::Common::DOCROOT = $d;
    my $b   = Lazysite::Manager::Common::form_bindings();
    my %got = map { $_ => '' } keys %want;
    for my $form ( keys %$b ) {
        for my $page ( grep { m{\Aq15f/} } @{ $b->{$form} } ) { $got{$page} = $form }
    }
    is_deeply( \%got, \%want, 'every page is bound to the form the processor renders, and only that' );
    cmp_ok( scalar( grep { length } values %want ), '>=', 20, 'and most of them bind one (not vacuous)' );
};

# Front matter assembled from fragments, seeded so a failure reproduces.
subtest 'generated front matter' => sub {
    my $seed = 9761;
    srand $seed;
    my @frag = ( "form: a\n", "form: b.c\n", "form:\n", "  d\n", "form: 'e'\n", "title:\n", "x: y\n",
        "\n", "form: [% f %]\n", "form: \"\"\n", "tags:\n  - t\n", " form: g\n", "form :h\n", "é:\n",
        "form:\r\n", "i\r\n", "form:\x{A0}j\n", "# form: k\n" );
    my $bad = 0;
    for ( 1 .. 2000 ) {
        my $fm = join '', map { $frag[ int rand @frag ] } 1 .. 1 + int rand 5;
        my $t  = "---\n$fm---\nbody\n";
        my ( $l, $p ) = ( lib_form($t), proc_form($t) );
        next if ( $l // "\0" ) eq ( $p // "\0" );
        $bad++;
        diag( "seed $seed: differ on " . ( $t =~ s/\n/\\n/gr ) ) if $bad <= 5;
    }
    is( $bad, 0, '2000 generated pages read alike' );
};

# A byte string about to be written raw is read as the processor reads it back.
subtest 'bytes are read as the processor reads them' => sub {
    my $t     = "---\x{A0}\nform: leads\n---\n";
    my $bytes = $t;
    utf8::encode($bytes);
    is( lib_form( Lazysite::Manager::Common::text_as_processor_reads($bytes) ), proc_form($t),
        'text_as_processor_reads decodes UTF-8 bytes first' );
};

done_testing();
