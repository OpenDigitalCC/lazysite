#!/usr/bin/perl
# SM1085: an extension config field shows its note.
#
# The release manager, 2026-10-16, on the Odoo extension's Configure form:
# "what does Extra operation packs mean on odoo config - add some tooltips to
# the items". The descriptor already explained the field - every config_schema
# entry may carry a `note`, and most of Odoo's did - but renderForm drew the
# label and the input and never the note, on every extension. The
# explanations existed and nobody could read them.
#
# What this holds:
#
# - renderForm, driven in node, puts a field's note beside its label as the
#   info mark (title and aria-label, escaped), and a field without one gets no
#   empty mark
# - every Odoo config field carries a note, so the form explains itself
use strict;
use warnings;
use Test::More;
use File::Temp ();
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $root = repo_root();

subtest 'every Odoo config field explains itself' => sub {
    my $json = `\Q$^X\E \Q$root/plugins/odoo.pl\E --describe 2>/dev/null`;
    my $desc = eval { JSON::PP::decode_json($json) } or return fail('odoo --describe');
    my @fields = @{ $desc->{config_schema} || [] };
    ok @fields, 'the schema has fields';
    for my $f (@fields) {
        ok length( $f->{note} // '' ), "$f->{key} has a note";
    }
};

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 1 unless length $node && -x $node;
    my $page = PageScript::page_source("$root/starter/manager/plugin-config.md");
    my $fns  = join "\n", map { PageScript::extract_function( $page, $_ ) } qw(esc renderForm);
    my $plugin = encode_json(
        {   id => 'x', _script => 'x.pl',
            config_schema => [
                { key => 'a', label => 'Explained', type => 'text', note => 'Says "why" & <how>' },
                { key => 'b', label => 'Bare',      type => 'text' },
            ],
        }
    );
    my $dir = File::Temp->newdir;
    open my $fh, '>', "$dir/t.js" or die "t.js: $!";
    print {$fh} $fns, "\nconsole.log(renderForm($plugin, {}));\n";
    close $fh;
    my $html = `\Q$node\E \Q$dir/t.js\E 2>&1`;

    subtest 'renderForm draws the note as the info mark' => sub {
        like $html,
            qr{<label>Explained <span class="mg-info" tabindex="0" role="img" aria-label="Says &quot;why&quot; &amp; &lt;how&gt;" title="Says &quot;why&quot; &amp; &lt;how&gt;">&#9432;</span></label>},
            'the note is beside the label, escaped, reachable by keyboard';
        like $html, qr{<label>Bare</label>}, 'a field with no note gets no empty mark';
    };
}

done_testing;
