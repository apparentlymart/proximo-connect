
use strict;
use warnings;

use XML::XPath;
use JSON::Any;
use File::Path;
use FindBin;

my %nodes = ();
my %relations = ();
my %nodes_by_type = ();
my %relations_by_type = ();

# Enclose this in a block so that all of the XML
# junk will get freed when we're done.
{
    my $xml = join('', <>);
    my $xp = XML::XPath->new(xml => $xml);

    my ($root_elem) = $xp->find("/osm")->get_nodelist;

    foreach my $item_elem ($root_elem->getChildNodes) {
        next unless $item_elem->getNodeType == XML::XPath::Node::ELEMENT_NODE;
        my $elem_name = $item_elem->getLocalName;

        if ($elem_name eq 'node') {
            my $node_elem = $item_elem;
            my $id = $node_elem->getAttribute('id')*-1;
            my $lat = $node_elem->getAttribute('lat') + 0;
            my $lon = $node_elem->getAttribute('lon') + 0;
            my $node = node($id);
            $node->{lat} = $lat;
            $node->{lon} = $lon;
            foreach my $child_elem ($node_elem->getChildNodes) {
                next unless $child_elem->getNodeType == XML::XPath::Node::ELEMENT_NODE;
                my $elem_name = $child_elem->getLocalName;

                if ($elem_name eq 'tag') {
                    my $k = $child_elem->getAttribute('k');
                    my $v = $child_elem->getAttribute('v');
                    $node->{tags}{$k} = $v;
                }
            }

            my $type = $node->{tags}{type};
            if ($type) {
                $nodes_by_type{$type} ||= [];
                push @{$nodes_by_type{$type}}, $node;
            }
        }
        elsif ($elem_name eq 'relation') {
            my $relation_elem = $item_elem;
            my $id = $relation_elem->getAttribute('id')*-1;
            my $relation = relation($id);
            foreach my $child_elem ($relation_elem->getChildNodes) {
                next unless $child_elem->getNodeType == XML::XPath::Node::ELEMENT_NODE;
                my $elem_name = $child_elem->getLocalName;

                if ($elem_name eq 'tag') {
                    my $k = $child_elem->getAttribute('k');
                    my $v = $child_elem->getAttribute('v');
                    $relation->{tags}{$k} = $v;
                }
                elsif ($elem_name eq 'member') {
                    my $type = $child_elem->getAttribute('type');
                    my $id = $child_elem->getAttribute('ref')*-1;
                    my $role = $child_elem->getAttribute('role');

                    if ($type eq 'node') {
                        my $node = node($id);
                        push @{$node->{relations}}, $relation;
                        push @{$relation->{nodes}}, $node;
                    }
                    elsif ($type eq 'relation') {
                        my $child_relation = relation($id);
                        push @{$child_relation->{parent_relations}}, $relation;
                        push @{$relation->{child_relations}}, $child_relation;
                    }

                }
            }

            my $type = $relation->{tags}{type};
            if ($type) {
                $relations_by_type{$type} ||= [];
                push @{$relations_by_type{$type}}, $relation;
            }
        }

    }

    my $relation_elems = $xp->find("/osm/node");
}

# 2nd pass: populate the by_type members now that we know we have
# all of the type tags loaded.
foreach my $relation (values %relations) {
    my $relation_type = $relation->{tags}{type};
    foreach my $node (@{$relation->{nodes}}) {
        my $node_type = $node->{tags}{type};
        $relation->{nodes_by_type}{$node_type} ||= [];
        push @{$relation->{nodes_by_type}{$node_type}}, $node;
        if (defined($relation_type)) {
            $node->{relations_by_type}{$relation_type} ||= [];
            push @{$node->{relations_by_type}{$relation_type}}, $relation;
        }
    }
    foreach my $child_relation (@{$relation->{child_relations}}) {
        my $child_relation_type = $child_relation->{tags}{type};
        $relation->{child_relations_by_type}{$child_relation_type} ||= [];
        push @{$relation->{child_relations_by_type}{$child_relation_type}}, $child_relation;
        if (defined($relation_type)) {
            $child_relation->{parent_relations_by_type}{$relation_type} ||= [];
            push @{$child_relation->{parent_relations_by_type}{$relation_type}}, $relation;
        }
    }
}

# Now produce JSON files representing this data sliced in useful ways.
chdir("$FindBin::Bin/../out");
my $json = JSON::Any->new(pretty => 1);

foreach my $street (@{$relations_by_type{street}}) {
    my $id = $street->{id};

    my $dict = street_as_dict($street);

    my %street_streets;
    my %street_runs;

    my $stops_dict = {};
    my $stops = $stops_dict->{items} = [];
    foreach my $stop (@{$street->{nodes_by_type}{stop}}) {
        push @$stops, stop_as_dict($stop);

        foreach my $other_street (@{$stop->{relations_by_type}{street}}) {
            my $other_id = $other_street->{id};
            next if $id == $other_id;
            $street_streets{$other_id} = $other_street;
        }

        foreach my $run (@{$stop->{relations_by_type}{run}}) {
            my $run_id = $run->{id};
            $street_runs{$run_id} = $run;
        }
    }
    write_json("streets/$id/stops", $stops_dict);

    my @streets = sort { $a->{tags}{name} cmp $b->{tags}{name} } values %street_streets;
    my $streets_dict = { items => [ map { street_as_dict($_) } @streets ] };
    write_json("streets/$id/streets", $streets_dict);

    my $runs_dict = {};
    foreach my $run (values %street_runs) {
        # There should only ever actually be one of these, but let's loop anyway to make sure.
        foreach my $route (@{$run->{parent_relations_by_type}{route}}) {
            my $route_id = $route->{id};
            unless ($runs_dict->{$route->{id}}) {
                $runs_dict->{$route_id} = {};
                $runs_dict->{$route_id}{route} = route_as_dict($route);
                $runs_dict->{$route_id}{runs} = [];
            }
            push @{$runs_dict->{$route_id}{runs}}, run_as_dict($run);
        }
    }
    write_json("streets/$id/runs", $runs_dict);

    write_json("streets/$id", $dict);
}

sub node {
    my ($id) = @_;

    return $nodes{$id} if exists($nodes{$id});
    return $nodes{$id} = Node->new($id);
}

sub relation {
    my ($id) = @_;

    return $relations{$id} if exists($relations{$id});
    return $relations{$id} = Relation->new($id);
}

sub write_json {
    my ($fn, $dict) = @_;

    my $dir = $fn;
    $dir =~ s!/[^/]+$!!;
    File::Path::mkpath($dir);

    my $enc = $json->encode($dict);
    open(OUT, '>', $fn.".json") or die "Failed to open $fn for writing: $!\n";
    print OUT $enc;
    close(OUT);
}

sub stop_as_dict {
    my ($stop) = @_;

    return {
        id => $stop->{id},
        name => $stop->{tags}{name},
        latitude => $stop->{lat},
        longitude => $stop->{lon},
    };
}

sub street_as_dict {
    my ($street) = @_;

    return {
        id => $street->{id},
        name => $street->{tags}{name},
    };
}

sub route_as_dict {
    my ($route) = @_;

    my ($agency) = @{$route->{parent_relations_by_type}{agency}};
    my $agency_id = $agency->{id} if $agency;

    return {
        id => $route->{id},
        name => $route->{tags}{name},
        (exists($route->{tags}{'pb:id'}) ? (pb_id => $route->{tags}{'pb:id'}) : ()),
        agency_id => $agency_id,
    };
}

sub run_as_dict {
    my ($run) = @_;

    return {
        id => $run->{id},
        name => $run->{tags}{name},
        (exists($run->{tags}{'pb:id'}) ? (pb_id => $run->{tags}{'pb:id'}) : ()),
    };
}

package Node;

sub new {
    my ($class, $id) = @_;
    return bless {
        id => $id,
        relations => [],
        relations_by_type => {},
        tags => {},
    }, $class;
}

package Relation;

sub new {
    my ($class, $id) = @_;
    return bless {
        id => $id,
        child_relations => [],
        child_relations_by_type => {},
        parent_relations => [],
        parent_relations_by_type => {},
        nodes => [],
        nodes_by_type => {},
        tags => {},
    }, $class;
}

1;

