# encoding: UTF-8
#
# 顶点集合：收集选择集（含下级组/组件）中的全部顶点，
# 并用"世界坐标 -> 新世界坐标"的函数整体移动顶点。
#
# 使用 Sketchup::Entities#transform_by_vectors，因此材质、贴图坐标、
# 柔化/平滑、组与组件结构都会被保留，而且可以反复重算（实时预览）
# 或一键还原。

require 'sketchup.rb'
require File.join(File.dirname(__FILE__), 'vec_math.rb')

module Ban
  module TaperScale
    class VertexSet
      Entry = Struct.new(:entities, :vertex, :world, :to_local)

      MAX_DEPTH = 12

      def initialize
        @entries = []
        @seen = {}
      end

      def size
        @entries.size
      end

      def empty?
        @entries.empty?
      end

      # 收集到的顶点（可用于调试 / 自检）
      def vertices
        @entries.map { |entry| entry.vertex }
      end

      # 收集时记录的原始世界坐标
      def original_positions
        @entries.map { |entry| entry.world }
      end

      # targets      活动上下文中的实体数组
      # edit_tr      活动上下文 -> 世界 的变换
      # parent_ents  targets 所在的 Entities 集合
      def collect(targets, edit_tr, parent_ents, unique: true, explode_curves: false)
        targets.each do |entity|
          walk(entity, parent_ents, edit_tr, unique, explode_curves, 0)
        end
        self
      end

      # 还原到收集时的位置。
      def reset
        apply { |world| world }
      end

      # 按变形函数移动所有顶点。函数接收原始世界坐标，返回新的世界坐标。
      def apply
        buckets = {}
        @entries.each do |entry|
          target_local = yield(entry.world).transform(entry.to_local)
          vector = VecMath.point_minus(target_local, entry.vertex.position)
          next if VecMath.length(vector) < 1.0e-9

          (buckets[entry.entities] ||= []) << [entry.vertex, vector]
        end

        buckets.each do |entities, pairs|
          vertices = pairs.map { |pair| pair[0] }
          vectors = pairs.map { |pair| pair[1] }
          entities.transform_by_vectors(vertices, vectors)
        end
        nil
      end

      private

      def walk(entity, parent_ents, transformation, unique, explode, depth)
        return if depth > MAX_DEPTH

        if instance?(entity)
          child_ents = prepare_instance(entity, unique)
          return unless child_ents

          walk_entities(child_ents, transformation * entity.transformation,
                        unique, explode, depth)
        elsif entity.is_a?(Sketchup::Edge) || entity.is_a?(Sketchup::Face)
          entity.vertices.each { |vertex| add(vertex, parent_ents, transformation) }
        elsif entity.is_a?(Sketchup::Vertex)
          add(entity, parent_ents, transformation)
        end
      end

      def walk_entities(entities, transformation, unique, explode, depth)
        if explode
          entities.grep(Sketchup::Edge).each do |edge|
            begin
              edge.explode_curve
            rescue StandardError
              nil
            end
          end
        end

        entities.grep(Sketchup::Edge).each do |edge|
          edge.vertices.each { |vertex| add(vertex, entities, transformation) }
        end

        entities.each do |child|
          next unless instance?(child)

          walk(child, entities, transformation, unique, explode, depth + 1)
        end
      end

      def add(vertex, entities, transformation)
        return unless vertex.valid?
        return if @seen.key?(vertex.entityID)

        @seen[vertex.entityID] = true
        world = vertex.position.transform(transformation)
        @entries << Entry.new(entities, vertex, world, transformation.inverse)
      end

      def instance?(entity)
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      end

      # 需要单独变形时，先让组件/组独立，避免影响同一定义的其他实例。
      def prepare_instance(instance, unique)
        entities = instance_entities(instance)
        return nil unless entities

        if unique
          begin
            definition = instance.definition
            if definition && definition.instances.length > 1
              instance.make_unique
              entities = instance_entities(instance)
            end
          rescue StandardError
            nil
          end
        end
        entities
      end

      def instance_entities(instance)
        if instance.respond_to?(:definition)
          begin
            definition = instance.definition
            return definition.entities if definition
          rescue StandardError
            nil
          end
        end
        return instance.entities if instance.is_a?(Sketchup::Group)

        nil
      rescue StandardError
        nil
      end
    end
  end
end
