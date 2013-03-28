class OldRelation < ActiveRecord::Base
  include ConsistencyValidations
  
  self.table_name = "relations"
  self.primary_keys = "relation_id", "version"

  # note this needs to be included after the table name changes, or
  # the queries generated by Redactable will use the wrong table name.
  include Redactable

  belongs_to :changeset
  belongs_to :redaction
  belongs_to :current_relation, :class_name => "Relation", :foreign_key => "relation_id"

  has_many :old_members, :class_name => 'OldRelationMember', :foreign_key => [:relation_id, :version], :order => :sequence_id
  has_many :old_tags, :class_name => 'OldRelationTag', :foreign_key => [:relation_id, :version]
  
  validates_associated :changeset

  def self.from_relation(relation)
    old_relation = OldRelation.new
    old_relation.visible = relation.visible
    old_relation.changeset_id = relation.changeset_id
    old_relation.timestamp = relation.timestamp
    old_relation.relation_id = relation.id
    old_relation.version = relation.version
    old_relation.members = relation.members
    old_relation.tags = relation.tags
    return old_relation
  end

  def save_with_dependencies!

    # see comment in old_way.rb ;-)
    save!
    clear_aggregation_cache
    clear_association_cache
    @attributes.update(OldRelation.where(:relation_id => self.relation_id, :timestamp => self.timestamp).order("version DESC").first.instance_variable_get('@attributes'))

    # ok, you can touch from here on

    self.tags.each do |k,v|
      tag = OldRelationTag.new
      tag.k = k
      tag.v = v
      tag.relation_id = self.relation_id
      tag.version = self.version
      tag.save!
    end

    self.members.each_with_index do |m,i|
      member = OldRelationMember.new
      member.id = [self.relation_id, self.version, i]
      member.member_type = m[0].classify
      member.member_id = m[1]
      member.member_role = m[2]
      member.save!
    end
  end

  def members
    unless @members
      @members = Array.new
      OldRelationMember.where(:relation_id => self.relation_id, :version => self.version).order(:sequence_id).each do |m|
        @members += [[m.type,m.id,m.role]]
      end
    end
    @members
  end

  def tags
    unless @tags
      @tags = Hash.new
      OldRelationTag.where(:relation_id => self.relation_id, :version => self.version).each do |tag|
        @tags[tag.k] = tag.v
      end
    end
    @tags = Hash.new unless @tags
    @tags
  end

  def members=(s)
    @members = s
  end

  def tags=(t)
    @tags = t
  end

  def to_xml
    doc = OSM::API.new.get_xml_doc
    doc.root << to_xml_node()
    return doc
  end

  def to_xml_node(changeset_cache = {}, user_display_name_cache = {})
    el1 = XML::Node.new 'relation'
    el1['id'] = self.relation_id.to_s
    el1['visible'] = self.visible.to_s
    el1['timestamp'] = self.timestamp.xmlschema
    el1['version'] = self.version.to_s
    el1['changeset'] = self.changeset_id.to_s

    if changeset_cache.key?(self.changeset_id)
      # use the cache if available
    else
      changeset_cache[self.changeset_id] = self.changeset.user_id
    end

    user_id = changeset_cache[self.changeset_id]

    if user_display_name_cache.key?(user_id)
      # use the cache if available
    elsif self.changeset.user.data_public?
      user_display_name_cache[user_id] = self.changeset.user.display_name
    else
      user_display_name_cache[user_id] = nil
    end

    if not user_display_name_cache[user_id].nil?
      el1['user'] = user_display_name_cache[user_id]
      el1['uid'] = user_id.to_s
    end
    
    el1['redacted'] = self.redaction.id.to_s if self.redacted?
    
    self.old_members.each do |member|
      e = XML::Node.new 'member'
      e['type'] = member.member_type.to_s.downcase
      e['ref'] = member.member_id.to_s # "id" is considered uncool here as it should be unique in XML
      e['role'] = member.member_role.to_s
      el1 << e
    end
    
    self.old_tags.each do |tag|
      e = XML::Node.new 'tag'
      e['k'] = tag.k
      e['v'] = tag.v
      el1 << e
    end

    return el1
  end

  # Temporary method to match interface to nodes
  def tags_as_hash
    return self.tags
  end

  # Temporary method to match interface to relations
  def relation_members
    return self.old_members
  end

  # Pretend we're not in any relations
  def containing_relation_members
    return []
  end

  # check whether this element is the latest version - that is,
  # has the same version as its "current" counterpart.
  def is_latest_version?
    current_relation.version == self.version
  end
end
