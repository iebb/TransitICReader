package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.CalypsoProtocol
import ad.neko.cardbal.android.nfc.CepasProtocol
import ad.neko.cardbal.android.nfc.StoredValueProtocol
import ad.neko.cardbal.android.util.hexToBytes
import ad.neko.cardbal.android.util.hexString
import kotlinx.datetime.Instant

internal object AdditionalCardHistory {
    private val families=setOf("ez-link","nets flashpay","opal","hsl","waltti","clipper","calypso","lignes d'azur card","navigo","opus","mobib","rav-kav")
    fun handles(family:String)=family.lowercase() in families
    fun merge(records:List<String>):List<String> = CalypsoProtocol.mergeHistory(records).distinctBy { raw ->
        val b=raw.hexToBytes()
        when {
            b.size>=12 && b.copyOfRange(0,5).contentEquals(byteArrayOf(0x44,0x46,0x53,0x56,1)) -> (b.copyOfRange(0,7)+b.copyOfRange(9,b.size)).hexString()
            else -> raw.uppercase()
        }
    }
    fun decode(raw:String,family:String,context:List<String> = emptyList()):TransitTransaction? {
        val name=family.lowercase()
        if(name=="ez-link" || name=="nets flashpay") {
            val h=CepasProtocol.decodeHistory(raw.hexToBytes()) ?: return null
            val category=when(h.kind) {
                CepasProtocol.Kind.Train->TransactionCategory.train
                CepasProtocol.Kind.Bus->TransactionCategory.bus
                CepasProtocol.Kind.TopUp->TransactionCategory.topUp
                CepasProtocol.Kind.Refund->TransactionCategory.refund
                CepasProtocol.Kind.Purchase,CepasProtocol.Kind.Service->TransactionCategory.payment
                else->TransactionCategory.unknown
            }
            return TransitTransaction(date=h.epochSeconds?.let(Instant::fromEpochSeconds),amount=h.amountMinor,
                type=h.type,category=category,location=h.userData,rawData=raw,currencyCode="SGD",fractionDigits=2,
                issuerTimeZone="Asia/Singapore",amountIsSigned=true,amountKnown=h.hasMonetaryAmount)
        }
        val canonical=mapOf("opal" to "Opal","hsl" to "HSL","waltti" to "Waltti","clipper" to "Clipper")[name]
        if(canonical!=null) {
            val h=StoredValueProtocol.parseHistories(if(context.isEmpty()) listOf(raw) else merge(context),canonical).firstOrNull{it.rawEnvelope==raw} ?: return null
            val category=when {h.kind=="reload"->TransactionCategory.topUp;h.label=="Tap on"->TransactionCategory.tapOn;h.label=="Tap off"->TransactionCategory.tapOff;else->TransactionCategory.train}
            return TransitTransaction(date=h.dateEpochSeconds?.let(Instant::fromEpochSeconds),amount=h.amountMinor ?: 0,
                balanceAfter=h.balanceMinor,type=h.label,category=category,terminalID=h.route,location=h.locationCode,
                rawData=raw,currencyCode=h.currencyCode,fractionDigits=2,issuerTimeZone=h.issuerTimeZone,
                amountIsSigned=true,amountKnown=h.amountMinor!=null,recordNumber=h.counter)
        }
        val h=CalypsoProtocol.parseHistory(raw.hexToBytes())?.takeIf{it.network.family.lowercase()==name} ?: return null
        return TransitTransaction(date=h.timestampMillis?.let(Instant::fromEpochMilliseconds),amount=h.amountMinor ?: 0,
            type=h.description,category=TransactionCategory.train,terminalID=h.operatorCode,
            location=listOfNotNull(h.routeCode?.let{"Route $it"},h.stationCode?.let{"Station code $it"}).joinToString(" · ").ifEmpty{null},
            rawData=raw,currencyCode=h.currency ?: "EUR",fractionDigits=2,issuerTimeZone=h.network.timeZone,
            amountIsSigned=true,amountKnown=h.amountMinor!=null,recordCounter=h.counter)
    }
}
