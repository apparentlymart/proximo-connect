#!/usr/bin/perl

use strict;
use warnings;

use JSON::Any;
use LWP::UserAgent;
use Data::Dump "pp";

my @agencies = @ARGV;
my @nodes = ();
my @relations = ();
my %stops = ();
my %routes = ();
my $next_id = 1;

my $json = JSON::Any->new();
my $ua = LWP::UserAgent->new();

foreach my $agency_id (@agencies) {

    my $agency = get_json("/agencies/%s", $agency_id);
    warn "Processing ".$agency->{display_name}."\n";

    my $agency_rel = new_relation();
    $agency_rel->{type} = 'agency';
    $agency_rel->{name} = $agency->{display_name};
    $agency_rel->{pbid} = $agency_id;

    my $routes_list = get_json("/agencies/%s/routes", $agency_id);
    my $routes = $routes_list->{items};

    foreach my $route (@$routes) {

        my $route_id = $route->{id};

        warn " * ".$route_id." (".$route->{display_name}.")\n";

        my $route_rel = new_relation();
        $route_rel->{type} = 'route';
        $route_rel->{name} = $route->{display_name};
        $route_rel->{pbid} = $route_id;
        $agency_rel->add_member($route_rel);

        my $runs_list = get_json("/agencies/%s/routes/%s/runs", $agency_id, $route_id);
        my $runs = $runs_list->{items};

        foreach my $run (@$runs) {

            my $run_id = $run->{id};

            warn "    * ".$run_id." (".$run->{display_name}.")\n";

            my $run_rel = new_relation();
            $run_rel->{type} = 'run';
            $run_rel->{name} = $run->{display_name};
            $run_rel->{pbid} = $run_id;
            $route_rel->add_member($run_rel);

            my $stops_list = get_json("/agencies/%s/routes/%s/runs/%s/stops", $agency_id, $route_id, $run_id);
            my $stops = $stops_list->{items};

            foreach my $stop (@$stops) {

                # Some agencies don't provide stop ids for all stops :(
                my $stop_id = $stop->{id} || 'fake'.next_id();

                my $stop_node = $stops{$stop_id};
                unless ($stop_node) {
                    $stop_node = $stops{$stop_id} = new_node();
                    $stop_node->{type} = 'stop';
                    $stop_node->{name} = $stop->{display_name};
                    $stop_node->{lat} = $stop->{latitude};
                    $stop_node->{lon} = $stop->{longitude};
                    $agency_rel->add_member($stop_node, $stop_id);
                }

                $route_rel->add_member($stop_node);
                $run_rel->add_member($stop_node);

            }
            

        }

    }

}



print qq{<osm version="0.6">\n};
foreach my $node (@nodes) {
    printf qq{  <node id="%s" visible="true" lat="%s" lon="%s">\n}, xml_encode($node->{id}), $node->{lat}, $node->{lon};
    printf qq{    <tag k="type"    v="%s" />\n}, xml_encode($node->{type});
    printf qq{    <tag k="name"    v="%s" />\n}, xml_encode($node->{name});
    printf qq{    <tag k="pb:id"   v="%s" />\n}, xml_encode($node->{pbid}) if defined($node->{pbid});

    # For some node types generate some extra tags just to get nice handling in OSM tools
    if ($node->{type} eq 'stop') {
        print qq{    <tag k="highway" v="bus_stop" />\n};
    }

    print  qq{  </node>\n};
}
foreach my $relation (@relations) {
    printf qq{  <relation id="%s" visible="true">\n}, xml_encode($relation->{id});
    printf qq{    <tag k="type"  v="%s" />\n}, xml_encode($relation->{type});
    printf qq{    <tag k="name"  v="%s" />\n}, xml_encode($relation->{name});
    printf qq{    <tag k="pb:id" v="%s" />\n}, xml_encode($relation->{pbid});
    foreach my $member (@{$relation->{members}}) {
        my $object = $member->[0];
        my $role   = $member->[1];
        my $type   = $object->isa('Relation') ? 'relation' : 'node';
        $role      = '' unless defined($role);

        printf qq{    <member type="$type" ref="%s" role="%s" />\n}, xml_encode($object->{id}), xml_encode($role);
    }
    print  qq{  </relation>\n};
}
print qq{</osm>\n};

sub get_json {
    my ($url_template, @parts) = @_;

    my $url = "http://proximobus.appspot.com".sprintf($url_template, map { url_encode($_) } @parts).".json";
    my $res = $ua->get($url);
    if ($res->is_success) {
        return $json->decode($res->content);
    }
    else {
        die "Failed to retrieve $url: ".$res->status_line;
    }
}

sub url_encode {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9\-])/sprintf("%%%02X", ord($1))/seg;
    return $s;
}

sub xml_encode {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

sub next_id {
    # JOSM uses negative ids to represent items that are not yet
    # in the main OSM database. Our data will never be in the main
    # OSM database, so let's follow that convention to avoid confusion.
    return -($next_id++);
}

sub new_relation {
    my $new = Relation->new(next_id());
    push @relations, $new;
    return $new;
}

sub new_node {
    my $new = Node->new(next_id());
    push @nodes, $new;
    return $new;
}

package Node;

sub new {
    my ($class, $id) = @_;
    return bless { id => $id }, $class;
}

package Relation;

sub new {
    my ($class, $id) = @_;
    return bless { id => $id, members => [] }, $class;
}

sub add_member {
    my ($self, $object, $role) = @_;
    return if grep { $_->[0]{id} eq $object->{id} } @{$self->{members}};
    push @{$self->{members}}, [ $object, $role ];
}

