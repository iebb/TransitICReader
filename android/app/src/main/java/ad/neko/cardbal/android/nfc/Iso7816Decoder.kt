package ad.neko.cardbal.android.nfc

import android.nfc.Tag
import android.nfc.tech.IsoDep
import ad.neko.cardbal.android.data.*
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant

class Iso7816Decoder : TransitCardDecoder {
    override fun canDecode(tag: Tag): Boolean = IsoDep.get(tag) != null
    override fun decode(tag: Tag, scannedAt: Instant): TransitCardSnapshot? {
        val isoDep = IsoDep.get(tag) ?: return null
        isoDep.use { iso ->
            iso.connect(); iso.timeout = 2500
            val snapshots=mutableListOf<TransitCardSnapshot>()
            for (candidateAid in Iso7816Protocol.selectionAids) {
                val selection = runCatching { Iso7816Protocol.select(candidateAid,iso::transceive) }.getOrNull() ?: continue
                val snapshot=readApplication(tag.id.hexString(),selection,scannedAt,iso::transceive) ?: continue
                snapshots.add(snapshot)
                if(selection.application.currency!="CNY") break
            }
            return TransitApplication.combine(snapshots)
        }
    }

    internal fun readApplication(uid: String, selection: Iso7816Protocol.Selection, scannedAt: Instant, exchange: (ByteArray)->ByteArray): TransitCardSnapshot? {
        val (aid,family,currency)=selection.application
        val select=selection.response
        val balanceResponse=runCatching { exchange(Iso7816Protocol.balanceCommand(selection.application)) }.getOrNull()
        val snapperCandidate=aid==SnapperPlusProtocol.APPLICATION_AID && SnapperPlusProtocol.purseIssuer(select.dropLast(2).toByteArray())==2
        if(snapperCandidate && (balanceResponse==null || SnapperPlusProtocol.balanceMinor(balanceResponse)==null)) return null
        val snapper=if(snapperCandidate) SnapperPlusProtocol.read(aid,select,balanceResponse!!,exchange) else null
        val purse=if(currency=="KRW" && snapper==null) {
            IsoRecordReader.command("00B2011400".hexToBytes(),exchange)?.let(KoreanCardFormat::purse)
                ?: KoreanCardFormat.purse(select.dropLast(2).toByteArray())
        } else null
        val resolvedFamily=when { snapper!=null -> "Snapper+";purse?.isUMoney==true -> "U-Money";else -> family }
        val fields=mutableListOf(ResultField("Selected AID",aid),ResultField("Brand",if(purse?.isClimate==true) "Climate Card" else resolvedFamily))
        var serial=if(snapper!=null) SnapperPlusProtocol.purseSerial(select.dropLast(2).toByteArray()) else purse?.serial
        var city: String?=null
        var balance=balanceResponse?.let(Iso7816Protocol::balanceValue)?.let { value ->
            formatCardMoney(if(currency=="CNY") value and 0x7fffffff else value,if(purse?.isUMoney==true) "MNT" else currency,if(currency=="CNY") 2 else 0)
        }
        if(family=="China T-Union") {
            val stored=balanceResponse?.let(Iso7816Protocol::balanceValue)
            val debt=runCatching{exchange("805C010204".hexToBytes())}.getOrNull()?.let(Iso7816Protocol::balanceValue) ?: 0L
            if(stored!=null) balance=formatCardMoney(stored-debt,"CNY",2)
        }
        if(snapper!=null) balance=formatCardMoney(snapper.balanceMinor,"NZD",2)
        if(purse?.isClimate==true) balance=null
        purse?.issueDate?.let{fields.add(ResultField("Issue Date",it))};purse?.expiryDate?.let{fields.add(ResultField("Expiry Date",it))}
        val records=mutableListOf<TransitApplicationRecord>()
        if(currency=="CNY") {
            val info=if(family=="City Union") {
                IsoRecordReader.command("00B095001E".hexToBytes(),exchange)
                    ?: run {
                        if(IsoRecordReader.command("00A4000002001500".hexToBytes(),exchange)!=null) IsoRecordReader.command("00B0000000".hexToBytes(),exchange) else null
                    }
            } else KoreanCardFormat.tlv(select.dropLast(2).toByteArray(),0x9f0c)
            if(info!=null) {
                city=info.takeIf{it.size>=4}?.copyOfRange(2,4)?.hexString()
                if(family=="City Union" && info.size>=20) serial=JapaneseCardFormats.uint(info,16,4,city!="2000").takeIf{it!=0L}?.toString()
                if(family=="China T-Union" && info.size>=20) {
                    var can=info.copyOfRange(10,20).hexString().trimEnd('F')
                    if(can.length==20 && can.startsWith("0")) can=can.drop(1)
                    if(can.length in 16..19 && can.all{it in '0'..'9'} && can.any{it!='0'}) serial=can
                }
                for((offset,title) in listOf(20 to "Issue Date",24 to "Expiry Date")) {
                    if(info.size>=offset+4) KoreanCardFormat.bcdTimestamp(info.copyOfRange(offset,offset+4)+byteArrayOf(0,0,0),"Asia/Shanghai")?.let{
                        fields.add(ResultField(title,java.time.Instant.ofEpochMilli(it.toEpochMilliseconds()).atZone(java.time.ZoneId.of("Asia/Shanghai")).toLocalDate().toString()))
                    }
                }
                fields.add(ResultField("App Metadata",info.hexString()))
                city?.let { fields.add(ResultField("Issuing City",if(it=="2000") "上海市" else it)) }
            }
            // A file SELECT above changes the current DF. Always restore the application.
            if(IsoRecordReader.command(Iso7816Protocol.selectCommand(aid),exchange)==null) return null
            records+=IsoRecordReader.records(0x18,30,23,"transaction",exchange)
            if(family=="City Union" && city=="2000") {
                records+=IsoRecordReader.records(6,30,23,"transaction",exchange)
                records+=IsoRecordReader.records(0x10,30,23,"transaction",exchange)
                records+=IsoRecordReader.records(7,30,16,"auxiliary",exchange)
                records+=IsoRecordReader.records(0x11,2,16,"auxiliary",exchange)
                records+=IsoRecordReader.records(0x14,5,16,"auxiliary",exchange).filter{it.index==4 || it.index==5}
            }
            if(family=="China T-Union") records+=IsoRecordReader.records(0x1e,30,48,"transit",exchange)
        } else if(snapper!=null) {
            snapper.history.forEachIndexed { i,r -> records.add(TransitApplicationRecord("transaction",4,i+1,r.hexString())) }
        } else {
            val sfis=if(family=="NAMANE") listOf(14) else listOf(3,4)
            for(sfi in sfis) records+=IsoRecordReader.koreanRecords(sfi,exchange)
        }
        if(balance==null && records.none{it.kind!="auxiliary"} && purse?.isClimate!=true) return null
        serial?.let{fields.add(ResultField("Card Number",it))}
        if(purse?.isClimate==true) fields.add(ResultField("Ticket Status","Unlimited pass; no stored-value balance"))
        val snapshot=TransitCardSnapshot(technology="ISO7816",cardFamily=resolvedFamily,identifierLabel="UID",identifierValue=uid.chunked(4).joinToString(" "),rawIdentifierValue=uid,
            selectedAID=aid,balanceText=balance,balanceDetail=if(purse?.isClimate==true) "Climate Card (Unlimited Pass)" else if(snapper!=null) "Snapper+ on-card purse (NZD cents)" else "$resolvedFamily on-card balance",
            realSerialNumber=serial,resultFields=fields,
            rawSections=listOf(RawDataSection("Application",listOf(RawDataField("AID",aid),RawDataField("Select Response",select.hexString())))),
            rawTransactions=records.filter{it.kind=="transaction"}.map{it.hex},rawTransitHistory=records.filter{it.kind=="transit"}.map{it.hex},scannedAt=scannedAt)
        return if(currency=="CNY") snapshot.copy(applications=listOf(TransitApplication.from(snapshot,records,city))) else snapshot
    }
}

internal object IsoRecordReader {
    fun command(apdu: ByteArray, exchange: (ByteArray)->ByteArray): ByteArray? {
        var response=runCatching { exchange(apdu) }.getOrNull() ?: return null
        if(response.size==2 && response[0]==0x6c.toByte()) {
            response=runCatching { exchange(apdu.copyOf().apply{this[lastIndex]=response.last()}) }.getOrNull() ?: return null
        }
        return if(response.isSuccess) response.dropLast(2).toByteArray() else null
    }
    fun koreanRecords(sfi: Int,exchange:(ByteArray)->ByteArray):List<TransitApplicationRecord> {
        val kind=if(sfi==3) "transit" else "transaction"
        val direct=records(sfi,20,if(sfi==3) 18 else 14,kind,exchange)
        if(direct.isNotEmpty()) return direct
        val stride=if(sfi==3) 52 else if(sfi==14) 14 else 40
        val binary=command(byteArrayOf(0,0xb0.toByte(),(sfi or 0x80).toByte(),0,0),exchange)
        if(binary!=null && binary.size>=stride && binary.size%stride==0) {
            val rows=binary.toList().chunked(stride).mapIndexedNotNull { index,block ->
                if(block.all{it==0.toByte() || it==0xff.toByte()}) null else TransitApplicationRecord(kind,sfi,index+1,block.toByteArray().hexString())
            }
            if(rows.isNotEmpty()) return rows
        }
        return recordsWithP2(sfi,20,if(sfi==3) 18 else 14,kind,exchange,0)
    }
    fun records(sfi: Int,max: Int,minimum: Int,kind: String,exchange:(ByteArray)->ByteArray):List<TransitApplicationRecord> = recordsWithP2(sfi,max,minimum,kind,exchange,null)
    private fun recordsWithP2(sfi: Int, max: Int, minimum: Int, kind: String, exchange: (ByteArray)->ByteArray, p2: Int?): List<TransitApplicationRecord> {
        val rows=mutableListOf<TransitApplicationRecord>()
        for(index in 1..max) {
            val data=command(byteArrayOf(0,0xb2.toByte(),index.toByte(),(p2 ?: ((sfi shl 3) or 4)).toByte(),0),exchange) ?: break
            if(data.size<minimum) continue
            if(data.all{it==0.toByte()} || data.all{it==0xff.toByte()}) continue
            rows.add(TransitApplicationRecord(kind,sfi,index,data.hexString()))
        }
        return rows
    }
}
