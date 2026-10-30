package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.util.hexToBytes

/** Reconcile only unambiguous mirrored PBOC/travel evidence, preserving conflicts. */
internal object ChineseHistoryMerge {
    fun timestamp(data:ByteArray,dateStart:Int,timeStart:Int,zone:String):kotlinx.datetime.Instant? = runCatching {
        if(dateStart<0 || timeStart<0 || data.size<dateStart+4 || data.size<timeStart+3) return null
        fun bcd(index:Int):Int {
            val value=data[index].toInt() and 255
            require(value shr 4<=9 && value and 15<=9)
            return (value shr 4)*10+(value and 15)
        }
        val year=bcd(dateStart)*100+bcd(dateStart+1)
        if(year !in 1900..2199) return null
        val date=java.time.LocalDateTime.of(year,bcd(dateStart+2),bcd(dateStart+3),bcd(timeStart),bcd(timeStart+1),bcd(timeStart+2))
        val issuer=java.time.ZoneId.of(zone);val offset=issuer.rules.getValidOffsets(date).singleOrNull() ?: return null
        kotlinx.datetime.Instant.fromEpochMilliseconds(date.toInstant(offset).toEpochMilli())
    }.getOrNull()
    private fun amount(tx:TransitTransaction)=if(tx.amountIsSigned || tx.category in setOf(TransactionCategory.topUp,TransactionCategory.refund)) tx.amount else -tx.amount
    private fun purchase(tx:TransitTransaction):Boolean {
        val b=tx.rawData?.hexToBytes() ?: return false
        return tx.currencyCode=="CNY" && b.size==23 && (b[9]==6.toByte() || b[9]==9.toByte())
    }
    fun reconcile(input:List<TransitTransaction>):List<TransitTransaction> {
        val purchases=input.filter(::purchase)
        val trips=input.filter{it.currencyCode=="CNY" && (it.rawData?.hexToBytes()?.size ?: 0)>=48}
        fun match(p:TransitTransaction,t:TransitTransaction):Boolean = p.date!=null && p.date==t.date && amount(p)==amount(t) &&
            (p.sourceApplicationID==t.sourceApplicationID || p.terminalID?.let{it.length==12 && it.any{c->c!='0'} && t.terminalID=="0000"+it}==true)
        val used=mutableSetOf<TransitTransaction>();val enriched=mutableMapOf<TransitTransaction,TransitTransaction>()
        for(p in purchases) {
            val t=trips.filter{match(p,it)}.singleOrNull() ?: continue
            if(purchases.count{match(it,t)}!=1) continue
            used.add(t)
            enriched[p]=p.copy(type=t.type,category=t.category,balanceAfter=t.balanceAfter,location=t.location ?: p.location,
                entryStation=t.entryStation,exitStation=t.exitStation,entryStationCode=t.entryStationCode,exitStationCode=t.exitStationCode)
        }
        val candidates=input.filter{it !in used}.map{enriched[it] ?: it}
        val groups=candidates.groupBy { tx -> if(purchase(tx) && tx.date!=null) "pboc:${tx.rawData!!.uppercase().drop(10)}" else "raw:${tx.sourceApplicationID}:${tx.rawData}:${tx.recordNumber}" }
        return groups.values.flatMap { group ->
            if(group.size<2 || group.any{it.sourceApplicationID==null} || group.map{it.sourceApplicationID}.distinct().size!=group.size) group
            else listOf(group.maxBy{(if(it.entryStation!=null || it.exitStation!=null) 4 else 0)+(if(it.location!=null) 2 else 0)})
        }.sortedByDescending{it.date}
    }
    fun cityUnionDirection(purchase:ByteArray,auxiliary:List<TransitApplicationRecord>):Boolean? {
        if(purchase.size!=23 || purchase[10]!=0x20.toByte() || purchase[11]!=0.toByte()) return null
        val directions=auxiliary.mapNotNull { record ->
            val b=record.hex.hexToBytes()
            if(b.size!=16 || b[0]==0.toByte() || b[1]==0.toByte() || !b.copyOfRange(6,9).contentEquals(purchase.copyOfRange(13,16)) || !b.copyOfRange(1,6).contentEquals(purchase.copyOfRange(17,22))) return@mapNotNull null
            when {record.sfi==0x11 && record.index==1 || record.sfi==0x14 && record.index==4 -> true
                record.sfi==0x11 && record.index==2 || record.sfi==0x14 && record.index==5 -> false
                else -> null}
        }.distinct()
        return directions.singleOrNull()
    }
}
