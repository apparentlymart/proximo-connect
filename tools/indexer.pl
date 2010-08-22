
use strict;
use warnings;

use XML::XPath;

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

foreach my $street (@{$relations_by_type{street}}) {
    print "$street->{tags}{name}\n";
    foreach my $stop (@{$street->{nodes}}) {
        print " * $stop->{tags}{name}\n";
    }
}

#use Data::Dumper;
#print Data::Dumper::Dumper($relations_by_type{station});

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

