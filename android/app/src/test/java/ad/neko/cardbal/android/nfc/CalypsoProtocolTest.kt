package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CalypsoProtocolTest {
    private val fixture = Json.parseToJsonElement(javaClass.getResource("/calypso_synthetic.json")!!.readText()).jsonObject
    private fun network(name: String) = CalypsoProtocol.Network.entries.single { it.name.equals(name, ignoreCase = true) }
    private fun records(case: JsonObject): List<CalypsoProtocol.Record> = case.getValue("records").jsonArray.map {
        val r=it.jsonObject; CalypsoProtocol.Record(r.getValue("sfi").jsonPrimitive.int,r.getValue("number").jsonPrimitive.int,r.getValue("payload").jsonPrimitive.content.hexToBytes())
    }
    private fun environment(name: String) = fixture.getValue("environments").jsonObject.getValue(name).jsonPrimitive.content.hexToBytes()
    private val success = byteArrayOf(0x90.toByte(),0)
    private val missing = byteArrayOf(0x6A,0x82.toByte())

    @Test fun networkIdentificationUsesEnvironmentAndNeverGenericApplicationRID() {
        fixture.getValue("environments").jsonObject.forEach { (name, data) ->
            assertEquals(name, network(name), CalypsoProtocol.identify(data.jsonPrimitive.content.hexToBytes()))
        }
        assertEquals(CalypsoProtocol.Network.Generic, CalypsoProtocol.identify(ByteArray(29)))
        assertEquals("Calypso",CalypsoProtocol.identify(environment("intercode")).family)
        assertEquals(CalypsoProtocol.Network.Generic, CalypsoProtocol.identify(environment("intercode").copyOf(28)))
        val absentPresence=environment("navigo").also { it[1]=(it[1].toInt() and 0xF7).toByte() }
        assertEquals(CalypsoProtocol.Network.Generic, CalypsoProtocol.identify(absentPresence))
        val futureMobib=environment("mobib").also { it[0]=0xFC.toByte() }
        assertEquals(CalypsoProtocol.Network.Generic, CalypsoProtocol.identify(futureMobib))
    }

    @Test fun contractsDecodeActualValidityTripCountersAndStoredValueUnits() {
        fixture.getValue("contracts").jsonArray.forEach { item ->
            val c=item.jsonObject; val name=c.getValue("name").jsonPrimitive.content
            val value=CalypsoProtocol.contracts(network(c.getValue("network").jsonPrimitive.content),records(c)).single()
            assertEquals(name,c.getValue("product").jsonPrimitive.long,value.productCode)
            assertEquals(name,c.getValue("trips").jsonPrimitive.longOrNull,value.remainingTrips)
            assertEquals(name,c.getValue("balance").jsonPrimitive.longOrNull,value.balanceMinor)
            assertEquals(name,c.getValue("start").jsonPrimitive.contentOrNull,value.validFrom)
            assertEquals(name,c.getValue("end").jsonPrimitive.contentOrNull,value.validUntil)
        }
    }

    @Test fun travelEventsUsePerNetworkLayoutsMinutesTimeZonesAndSignedMoney() {
        fixture.getValue("histories").jsonArray.forEach { item ->
            val c=item.jsonObject; val net=network(c.getValue("network").jsonPrimitive.content)
            val raw=CalypsoProtocol.encodeRecord(net,CalypsoProtocol.Record(8,1,c.getValue("payload").jsonPrimitive.content.hexToBytes()))!!
            val event=CalypsoProtocol.parseHistory(raw)
            if (c["invalid"]?.jsonPrimitive?.booleanOrNull==true) assertNull(c.getValue("name").jsonPrimitive.content,event)
            else {
                assertNotNull(c.getValue("name").jsonPrimitive.content,event)
                assertEquals(c.getValue("millis").jsonPrimitive.long,event!!.timestampMillis)
                assertEquals(c.getValue("amount").jsonPrimitive.longOrNull,event.amountMinor)
                assertEquals(c.getValue("code").jsonPrimitive.intOrNull,event.eventCode)
                assertEquals(net.currency,event.currency)
            }
        }
    }

    @Test fun envelopesRejectMalformedFutureOrWrongFileLayouts() {
        val event=fixture.getValue("histories").jsonArray.first().jsonObject
        val payload=event.getValue("payload").jsonPrimitive.content.hexToBytes()
        val raw=CalypsoProtocol.encodeRecord(CalypsoProtocol.Network.Navigo,CalypsoProtocol.Record(8,1,payload))!!
        assertNull(CalypsoProtocol.parseHistory(raw.copyOf(raw.size-1)))
        assertNull(CalypsoProtocol.parseHistory(raw+byteArrayOf(0)))
        assertNull(CalypsoProtocol.parseHistory(raw.clone().also { it[3]=2 }))
        assertNull(CalypsoProtocol.parseHistory(raw.clone().also { it[5]=9 }))
        assertNull(CalypsoProtocol.parseHistory(raw.clone().also { it[4]=0 }))
        assertNull(CalypsoProtocol.encodeRecord(CalypsoProtocol.Network.Navigo,CalypsoProtocol.Record(31,1,payload)))
    }

    @Test fun ringMovesDeduplicateEventsButPreserveContractAndCounterSlots() {
        fun raw(network: CalypsoProtocol.Network, sfi: Int, number: Int, bytes: ByteArray) =
            CalypsoProtocol.encodeRecord(network,CalypsoProtocol.Record(sfi,number,bytes))!!.joinToString("") { "%02X".format(it) }
        val payload=fixture.getValue("histories").jsonArray.first().jsonObject.getValue("payload").jsonPrimitive.content.hexToBytes()
        val old=raw(CalypsoProtocol.Network.Navigo,8,1,payload); val moved=raw(CalypsoProtocol.Network.Navigo,8,2,payload)
        assertEquals(listOf(moved),CalypsoProtocol.mergeHistory(listOf(moved,old)))
        val first=raw(CalypsoProtocol.Network.Navigo,9,1,payload); val second=raw(CalypsoProtocol.Network.Navigo,9,2,payload)
        assertEquals(listOf(first,second),CalypsoProtocol.mergeHistory(listOf(first,second)))
        assertEquals(listOf("unrecognized",moved),CalypsoProtocol.mergeHistory(listOf("unrecognized",moved,old)))
    }

    @Test fun guardedReaderPreservesSourcesAndRetainsZeroValueCounters() {
        val c=fixture.getValue("contracts").jsonArray.single { it.jsonObject.getValue("name").jsonPrimitive.content=="rav-zero" }.jsonObject
        val files=records(c).associateBy { it.sfi to it.number } + ((7 to 1) to CalypsoProtocol.Record(7,1,environment("ravKav")))
        val commands=mutableListOf<ByteArray>()
        var retry=false
        val result=CalypsoProtocol.read { command ->
            commands.add(command.clone())
            when {
                command[1]==0xA4.toByte() -> if (command[2]==4.toByte() || command.size==7) success else missing
                command[1]==0xB2.toByte() -> {
                    val sfi=(command[3].toInt() and 255) ushr 3; val number=command[2].toInt() and 255
                    if (sfi==7 && !retry) { retry=true; byteArrayOf(0x6C,0) }
                    else files[sfi to number]?.payload?.plus(success) ?: missing
                }
                else -> missing
            }
        }!!
        assertEquals("Rav-Kav",result.family); assertEquals(0L,result.balanceMinor); assertEquals("ILS 0.00",result.balanceText)
        assertTrue(result.hasDecodedData)
        assertTrue(result.fields.any { it.first.endsWith("Valid Until") })
        assertTrue(result.rawHistories.all { it.matches(Regex("[0-9A-F]+")) })
        assertTrue(result.records.any { it.sfi==10 && it.payload.contentEquals(ByteArray(3)) })
        assertTrue(commands.any { it[1]==0xB2.toByte() && it[3]==0x3C.toByte() && it.last()==0.toByte() })
        assertTrue(commands.all { it[1]==0xA4.toByte() || it[1]==0xB2.toByte() })
    }

    @Test fun legacyTicketCounterWorksWithoutGuessingNiceBranding() {
        val c=fixture.getValue("contracts").jsonArray.single { it.jsonObject.getValue("name").jsonPrimitive.content=="generic-intercode-ticket" }.jsonObject
        val files=records(c).associateBy { it.sfi to it.number } + ((7 to 1) to CalypsoProtocol.Record(7,1,environment("intercode")))
        val result=CalypsoProtocol.read { command ->
            if (command[1]==0xA4.toByte()) success
            else if (command[1]==0xB2.toByte()) files[((command[3].toInt() and 255) ushr 3) to (command[2].toInt() and 255)]?.payload?.plus(success) ?: missing
            else missing
        }!!
        assertEquals("Calypso",result.family); assertEquals(3L,result.remainingTrips); assertTrue(result.hasDecodedData)
        assertTrue(result.fields.any { it.second=="Product 191" })
        assertFalse(result.fields.any { "Nice" in it.second || "Azur" in it.second || "N Voyage" in it.second })
    }

    @Test fun publicFileSelectionFallbackAndFailedStatusesAreHandledConservatively() {
        var selectedEnvironment=false
        val result=CalypsoProtocol.read { command ->
            when {
                command[1]==0xA4.toByte() && command[2]==4.toByte() -> success
                command[1]==0xA4.toByte() && command.drop(5).toByteArray().contentEquals(byteArrayOf(0x20,0,0x20,1)) -> { selectedEnvironment=true; success }
                command[1]==0xB2.toByte() && command[3]==4.toByte() && selectedEnvironment && command[2]==1.toByte() -> environment("opus")+success
                else -> missing
            }
        }!!
        assertEquals("OPUS",result.family); assertTrue(result.records.any { it.sfi==7 }); assertFalse(result.hasDecodedData)
        assertNull(CalypsoProtocol.read { byteArrayOf(0x90.toByte(),1) })
        assertNull(CalypsoProtocol.read { environment("navigo")+byteArrayOf(0x69,0x82.toByte()) })
    }
}
