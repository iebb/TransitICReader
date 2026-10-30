package ad.neko.cardbal.android.data

import java.util.PriorityQueue

internal object TransitGeometry {
    data class Point(val longitude: Double,val latitude: Double)
    data class Edge(val to: String,val km: Double,val packed: String?,val reversed: Boolean=false)
    private const val alphabet="0123456789bcdefghjkmnpqrstuvwxyz"
    fun decodePath(value: String): List<Point>? {
        val precision=value.firstOrNull()?.digitToIntOrNull()?.takeIf{it in 1..9} ?: return null
        var offset=1;var previous="";val result=mutableListOf<Point>()
        while(offset<value.length) {
            val shared=value[offset++].digitToIntOrNull() ?: return null
            if(shared>minOf(previous.length,precision) || offset+precision-shared>value.length) return null
            val hash=previous.take(shared)+value.substring(offset,offset+precision-shared)
            offset+=precision-shared
            val low=doubleArrayOf(-180.0,-90.0);val high=doubleArrayOf(180.0,90.0);var bit=0
            for(c in hash) {
                val digit=alphabet.indexOf(c).takeIf{it>=0} ?: return null
                for(shift in 4 downTo 0) {
                    val axis=bit++%2;val mid=(low[axis]+high[axis])/2
                    if(digit and (1 shl shift)!=0) low[axis]=mid else high[axis]=mid
                }
            }
            result.add(Point((low[0]+high[0])/2,(low[1]+high[1])/2));previous=hash
            if(result.size>20000) return null
        }
        return result.takeIf{it.size>=2}
    }
    fun shortest(start: String,target: String,graph: Map<String,List<Edge>>): List<Pair<String,Edge>>? {
        val distances=mutableMapOf(start to 0.0);val previous=mutableMapOf<String,Pair<String,Edge>>()
        val queue=PriorityQueue(compareBy<Pair<Double,String>>{it.first});queue.add(0.0 to start)
        while(queue.isNotEmpty()) {
            val(cost,node)=queue.remove()
            if(cost>distances.getValue(node)) continue
            if(node==target) break
            for(edge in graph[node].orEmpty()) {
                if(!edge.km.isFinite() || edge.km<0) continue
                val candidate=cost+edge.km
                if(candidate<(distances[edge.to] ?: Double.POSITIVE_INFINITY)) {
                    distances[edge.to]=candidate;previous[edge.to]=node to edge;queue.add(candidate to edge.to)
                }
            }
        }
        if(target !in distances) return null
        val result=mutableListOf<Pair<String,Edge>>();var node=target
        while(node!=start) { val step=previous[node] ?: return null;result.add(step);node=step.first }
        return result.reversed()
    }
}
