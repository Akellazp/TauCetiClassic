/****************************************************
				BODYPARTS
****************************************************/
/obj/item/organ/external
	name = "external"

	// Strings
	var/broken_description            // fracture string if any.
	var/damage_state = "00"           // Modifier used for generating the on-mob damage overlay for this limb.

	// Damage vars.
	var/brute_dam = 0                 // Actual current brute damage.
	var/burn_dam = 0                  // Actual current burn damage.
	var/last_dam = -1                 // used in healing/processing calculations.
	var/max_damage = 0                // Damage cap

	// Appearance vars.
	var/body_part = null              // Part flag
	var/body_zone = null              // Unique identifier of this limb.
	var/icon_position = 0             // Used in mob overlay layering calculations.

	// Wound and structural data.
	var/wound_update_accuracy = 1     // how often wounds should be updated, a higher number means less often
	var/list/wounds = list()          // wound datum list.
	var/number_wounds = 0             // number of wounds, which is NOT wounds.len!
	var/list/children = list()        // Sub-limbs.
	var/list/bodypart_organs = list() // Internal organs of this body part
	var/sabotaged = 0                 // If a prosthetic limb is emagged, it will detonate when it fails.
	var/list/implants = list()        // Currently implanted objects.

	// Surgery vars.
	var/open = 0
	var/stage = 0
	var/cavity = 0

	// Will be removed, moved or refactored.
	var/obj/item/hidden = null // relation with cavity
	var/tmp/perma_injury = 0
	var/tmp/destspawn = 0 //Has it spawned the broken limb?
	var/tmp/amputated = 0 //Whether this has been cleanly amputated, thus causing no pain
	var/limb_layer = 0
	var/damage_msg = "\red You feel an intense pain"

/obj/item/organ/external/insert_organ()
	..()

	owner.bodyparts += src
	owner.bodyparts_by_name[body_zone] = src

	if(parent)
		parent.children += src

/****************************************************
			   DAMAGE PROCS
****************************************************/

/obj/item/organ/external/emp_act(severity)
	if(!(status & ORGAN_ROBOT))	//meatbags do not care about EMP
		return
	var/probability = 30
	var/damage = 15
	if(severity == 2)
		probability = 1
		damage = 3
	if(prob(probability))
		droplimb(1)
	else
		take_damage(damage, 0, 1, 1, used_weapon = "EMP")

/obj/item/organ/external/proc/take_damage(brute, burn, sharp, edge, used_weapon = null, list/forbidden_limbs = list())
	if((brute <= 0) && (burn <= 0))
		return 0

	if(status & ORGAN_DESTROYED)
		return 0
	if(status & ORGAN_ROBOT )

		var/brmod = 0.66
		var/bumod = 0.66

		if(ishuman(owner))
			var/mob/living/carbon/human/H = owner
			if(H.species && H.species.flags[IS_SYNTHETIC])
				brmod = H.species.brute_mod
				bumod = H.species.burn_mod

		brute *= brmod //~2/3 damage for ROBOLIMBS
		burn *= bumod //~2/3 damage for ROBOLIMBS

	// High brute damage or sharp objects may damage organs
	if(bodypart_organs.len && ( (sharp && brute >= 5) || brute >= 10) && prob(5))
		// Damage an internal organ
		var/obj/item/organ/internal/IO = pick(bodypart_organs)
		IO.take_damage(brute / 2)
		brute -= brute / 2

	if((status & ORGAN_BROKEN) && prob(40) && brute)
		owner.emote("scream",,, 1)	//getting hit on broken hand hurts
	if(used_weapon)
		add_autopsy_data("[used_weapon]", brute + burn)

	var/can_cut = (prob(brute*2) || sharp) && !(status & ORGAN_ROBOT)
	// If the limbs can break, make sure we don't exceed the maximum damage a limb can take before breaking
	if((brute_dam + burn_dam + brute + burn) < max_damage)
		if(brute)
			if(can_cut)
				createwound( CUT, brute )
			else
				createwound( BRUISE, brute )
		if(burn)
			createwound( BURN, burn )
	else
		//If we can't inflict the full amount of damage, spread the damage in other ways
		//How much damage can we actually cause?
		var/can_inflict = max_damage * config.organ_health_multiplier - (brute_dam + burn_dam)
		if(can_inflict)
			if (brute > 0)
				//Inflict all burte damage we can
				if(can_cut)
					createwound( CUT, min(brute,can_inflict) )
				else
					createwound( BRUISE, min(brute,can_inflict) )
				var/temp = can_inflict
				//How much mroe damage can we inflict
				can_inflict = max(0, can_inflict - brute)
				//How much brute damage is left to inflict
				brute = max(0, brute - temp)

			if (burn > 0 && can_inflict)
				//Inflict all burn damage we can
				createwound(BURN, min(burn,can_inflict))
				//How much burn damage is left to inflict
				burn = max(0, burn - can_inflict)
		//If there are still hurties to dispense
		if (burn || brute)
			if (status & ORGAN_ROBOT)
				droplimb(1) //Robot limbs just kinda fail at full damage.
			else
				//List body parts we can pass it to
				var/list/possible_points = list()
				if(parent)
					possible_points += parent
				if(children)
					possible_points += children
				if(forbidden_limbs.len)
					possible_points -= forbidden_limbs
				if(possible_points.len)
					//And pass the pain around
					var/obj/item/organ/external/BP = pick(possible_points)
					BP.take_damage(brute, burn, sharp, edge, used_weapon, forbidden_limbs + src)

	// sync the organ's damage with its wounds
	src.update_damages()

	//If limb took enough damage, try to cut or tear it off
	if(body_part != UPPER_TORSO && body_part != LOWER_TORSO) //as hilarious as it is, getting hit on the chest too much shouldn't effectively gib you.
		if(brute_dam >= max_damage * config.organ_health_multiplier)
			if( (edge && prob(5 * brute)) || (brute > 20 && prob(2 * brute)) )
				droplimb(1)
				return

	owner.updatehealth()

	var/result = update_icon()
	if(result)
		owner.UpdateDamageIcon(src)
	return result

/obj/item/organ/external/proc/heal_damage(brute, burn, internal = 0, robo_repair = 0)
	if(status & ORGAN_ROBOT && !robo_repair)
		return

	//Heal damage on the individual wounds
	for(var/datum/wound/W in wounds)
		if(brute == 0 && burn == 0)
			break

		// heal brute damage
		if(W.damage_type == CUT || W.damage_type == BRUISE)
			brute = W.heal_damage(brute)
		else if(W.damage_type == BURN)
			burn = W.heal_damage(burn)

	if(internal)
		status &= ~ORGAN_BROKEN
		perma_injury = 0

	//Sync the organ's damage with its wounds
	src.update_damages()
	owner.updatehealth()

	var/result = update_icon()
	if(result)
		owner.UpdateDamageIcon(src)
	return result

/*
This function completely restores a damaged organ to perfect condition.
*/
/obj/item/organ/external/proc/rejuvenate()
	damage_state = "00"
	if(status & ORGAN_ROBOT)	//Robotic body parts stay robotic.  Fix because right click rejuvinate makes IPC's body parts organic.
		status = ORGAN_ROBOT
	else
		status = 0
	perma_injury = 0
	brute_dam = 0
	open = 0
	burn_dam = 0
	germ_level = 0
	wounds.Cut()
	number_wounds = 0

	// handle organs
	for(var/obj/item/organ/internal/IO in bodypart_organs)
		IO.rejuvenate()

	// remove embedded objects and drop them on the floor
	for(var/obj/implanted_object in implants)
		if(!istype(implanted_object,/obj/item/weapon/implant))	// We don't want to remove REAL implants. Just shrapnel etc.
			implanted_object.loc = owner.loc
			implants -= implanted_object

	owner.updatehealth()


/obj/item/organ/external/proc/createwound(type = CUT, damage)
	if(damage == 0) return

	//moved this before the open_wound check so that having many small wounds for example doesn't somehow protect you from taking internal damage
	//Possibly trigger an internal wound, too.
	var/local_damage = brute_dam + burn_dam + damage
	if(damage > 15 && type != BURN && local_damage > 30 && prob(damage) && !(status & ORGAN_ROBOT))
		var/datum/wound/internal_bleeding/I = new (15)
		wounds += I
		owner.custom_pain("You feel something rip in your [name]!", 1)

	// first check whether we can widen an existing wound
	if(wounds.len > 0 && prob(max(50+(number_wounds-1)*10,90)))
		if((type == CUT || type == BRUISE) && damage >= 5)
			//we need to make sure that the wound we are going to worsen is compatible with the type of damage...
			var/list/compatible_wounds = list()
			for (var/datum/wound/W in wounds)
				if (W.can_worsen(type, damage))
					compatible_wounds += W

			if(compatible_wounds.len)
				var/datum/wound/W = pick(compatible_wounds)
				W.open_wound(damage)
				if(prob(25))
					//maybe have a separate message for BRUISE type damage?
					owner.visible_message("\red The wound on [owner.name]'s [name] widens with a nasty ripping voice.",\
					"\red The wound on your [name] widens with a nasty ripping voice.",\
					"You hear a nasty ripping noise, as if flesh is being torn apart.")
				return

	//Creating wound
	var/wound_type = get_wound_type(type, damage)

	if(wound_type)
		var/datum/wound/W = new wound_type(damage)

		//Check whether we can add the wound to an existing wound
		for(var/datum/wound/other in wounds)
			if(other.can_merge(W))
				other.merge_wound(W)
				W = null // to signify that the wound was added
				break
		if(W)
			wounds += W

/****************************************************
			   PROCESSING & UPDATING
****************************************************/

//Determines if we even need to process this organ.

/obj/item/organ/external/proc/need_process()
	if(status && (status & ORGAN_ROBOT)) // If it's robotic, that's fine it will have a status.
		return 1
	if(brute_dam || burn_dam)
		return 1
	if(last_dam != brute_dam + burn_dam) // Process when we are fully healed up.
		last_dam = brute_dam + burn_dam
		return 1
	else
		last_dam = brute_dam + burn_dam
	if(germ_level)
		return 1
	return 0

/obj/item/organ/external/process()
	// Process wounds, doing healing etc. Only do this every few ticks to save processing power
	if(owner.life_tick % wound_update_accuracy == 0)
		update_wounds()

	//Chem traces slowly vanish
	if(owner.life_tick % 10 == 0)
		for(var/chemID in trace_chemicals)
			trace_chemicals[chemID] = trace_chemicals[chemID] - 1
			if(trace_chemicals[chemID] <= 0)
				trace_chemicals.Remove(chemID)

	//Dismemberment
	if(status & ORGAN_DESTROYED)
		if(!destspawn)
			droplimb()
		return
	if(parent)
		if(parent.status & ORGAN_DESTROYED)
			status |= ORGAN_DESTROYED
			owner.update_body()
			return

	//Bone fracurtes
	if(brute_dam > min_broken_damage * config.organ_health_multiplier && !(status & ORGAN_ROBOT))
		src.fracture()
	if(!(status & ORGAN_BROKEN))
		perma_injury = 0

	//Infections
	update_germs()

//Updating germ levels. Handles organ germ levels and necrosis.
/*
The INFECTION_LEVEL values defined in setup.dm control the time it takes to reach the different
infection levels. Since infection growth is exponential, you can adjust the time it takes to get
from one germ_level to another using the rough formula:

desired_germ_level = initial_germ_level*e^(desired_time_in_seconds/1000)

So if I wanted it to take an average of 15 minutes to get from level one (100) to level two
I would set INFECTION_LEVEL_TWO to 100*e^(15*60/1000) = 245. Note that this is the average time,
the actual time is dependent on RNG.

INFECTION_LEVEL_ONE		below this germ level nothing happens, and the infection doesn't grow
INFECTION_LEVEL_TWO		above this germ level the infection will start to spread to internal and adjacent bodyparts
INFECTION_LEVEL_THREE	above this germ level the player will take additional toxin damage per second, and will die in minutes without
						antitox. also, above this germ level you will need to overdose on spaceacillin to reduce the germ_level.

Note that amputating the affected organ does in fact remove the infection from the player's body.
*/
/obj/item/organ/external/proc/update_germs()

	if((status & (ORGAN_ROBOT|ORGAN_DESTROYED)) || (owner.species && owner.species.flags[IS_PLANT])) //Robotic limbs shouldn't be infected, nor should nonexistant limbs.
		germ_level = 0
		return

	if(owner.bodytemperature >= 170)	//cryo stops germs from moving and doing their bad stuffs
		//** Syncing germ levels with external wounds
		handle_germ_sync()

		//** Handle antibiotics and curing infections
		handle_antibiotics()

		//** Handle the effects of infections
		handle_germ_effects()

/obj/item/organ/external/proc/handle_germ_sync()
	var/antibiotics = owner.reagents.get_reagent_amount("spaceacillin")
	for(var/datum/wound/W in wounds)
		//Open wounds can become infected
		if (owner.germ_level > W.germ_level && W.infection_check())
			W.germ_level++

	if (antibiotics < 5)
		for(var/datum/wound/W in wounds)
			//Infected wounds raise the organ's germ level
			if (W.germ_level > germ_level)
				germ_level++
				break	//limit increase to a maximum of one per second

/obj/item/organ/external/proc/handle_germ_effects()
	var/antibiotics = owner.reagents.get_reagent_amount("spaceacillin")

	if (germ_level > 0 && germ_level < INFECTION_LEVEL_ONE && prob(60))	//this could be an else clause, but it looks cleaner this way
		germ_level--	//since germ_level increases at a rate of 1 per second with dirty wounds, prob(60) should give us about 5 minutes before level one.

	if(germ_level >= INFECTION_LEVEL_ONE)
		//having an infection raises your body temperature
		var/fever_temperature = (owner.species.heat_level_1 - owner.species.body_temperature - 5)* min(germ_level/INFECTION_LEVEL_TWO, 1) + owner.species.body_temperature
		//need to make sure we raise temperature fast enough to get around environmental cooling preventing us from reaching fever_temperature
		owner.bodytemperature += between(0, (fever_temperature - T20C)/BODYTEMP_COLD_DIVISOR + 1, fever_temperature - owner.bodytemperature)

		if(prob(round(germ_level/10)))
			if (antibiotics < 5)
				germ_level++

			if (prob(10))	//adjust this to tweak how fast people take toxin damage from infections
				owner.adjustToxLoss(1)

	if(germ_level >= INFECTION_LEVEL_TWO && antibiotics < 5)
		//spread the infection to organs
		var/obj/item/organ/internal/target_organ = null	//make organs become infected one at a time instead of all at once
		for (var/obj/item/organ/internal/IO in bodypart_organs)
			if (IO.germ_level > 0 && IO.germ_level < min(germ_level, INFECTION_LEVEL_TWO))	//once the organ reaches whatever we can give it, or level two, switch to a different one
				if (!target_organ || IO.germ_level > target_organ.germ_level)	//choose the organ with the highest germ_level
					target_organ = IO

		if (!target_organ)
			//figure out which organs we can spread germs to and pick one at random
			var/list/candidate_organs = list()
			for (var/obj/item/organ/internal/IO in bodypart_organs)
				if (IO.germ_level < germ_level)
					candidate_organs += IO
			if (candidate_organs.len)
				target_organ = pick(candidate_organs)

		if (target_organ)
			target_organ.germ_level++

		//spread the infection to child and parent bodyparts
		if (children)
			for (var/obj/item/organ/external/BP in children)
				if (BP.germ_level < germ_level && !(BP.status & ORGAN_ROBOT))
					if (BP.germ_level < INFECTION_LEVEL_ONE * 2 || prob(30))
						BP.germ_level++

		if (parent)
			if (parent.germ_level < germ_level && !(parent.status & ORGAN_ROBOT))
				if (parent.germ_level < INFECTION_LEVEL_ONE * 2 || prob(30))
					parent.germ_level++

	if(germ_level >= INFECTION_LEVEL_THREE && antibiotics < 30)	//overdosing is necessary to stop severe infections
		if (!(status & ORGAN_DEAD))
			status |= ORGAN_DEAD
			to_chat(owner, "<span class='notice'>You can't feel your [name] anymore...</span>")
			owner.update_body()

		germ_level++
		owner.adjustToxLoss(1)

//Updating wounds. Handles wound natural I had some free spachealing, internal bleedings and infections
/obj/item/organ/external/proc/update_wounds()

	if((status & ORGAN_ROBOT)) //Robotic limbs don't heal or get worse.
		return

	for(var/datum/wound/W in wounds)
		// wounds can disappear after 10 minutes at the earliest
		if(W.damage <= 0 && W.created + 10 * 10 * 60 <= world.time)
			wounds -= W
			continue
			// let the GC handle the deletion of the wound

		// Internal wounds get worse over time. Low temperatures (cryo) stop them.
		if(W.internal && owner.bodytemperature >= 170)
			var/bicardose = owner.reagents.get_reagent_amount("bicaridine")
			var/inaprovaline = owner.reagents.get_reagent_amount("inaprovaline")
			if(!(W.can_autoheal() || (bicardose && inaprovaline)))	//bicaridine and inaprovaline stop internal wounds from growing bigger with time
				W.open_wound(0.1 * wound_update_accuracy)
			if(bicardose >= 30)	//overdose of bicaridine begins healing IB
				W.damage = max(0, W.damage - 0.2) // Bug: doesn't update W.current_stage

			owner.vessel.remove_reagent("blood",0.05 * W.damage * wound_update_accuracy)
			if(prob(1 * wound_update_accuracy))
				owner.custom_pain("You feel a stabbing pain in your [name]!",1)

		// slow healing
		var/heal_amt = 0

		// if damage >= 50 AFTER treatment then it's probably too severe to heal within the timeframe of a round.
		if (W.can_autoheal() && W.wound_damage() < 50)
			heal_amt += 0.5

		//we only update wounds once in [wound_update_accuracy] ticks so have to emulate realtime
		heal_amt = heal_amt * wound_update_accuracy
		//configurable regen speed woo, no-regen hardcore or instaheal hugbox, choose your destiny
		heal_amt = heal_amt * config.organ_regeneration_multiplier
		// amount of healing is spread over all the wounds
		heal_amt = heal_amt / (wounds.len + 1)
		// making it look prettier on scanners
		heal_amt = round(heal_amt,0.1)
		W.heal_damage(heal_amt)

		// Salving also helps against infection
		if(W.germ_level > 0 && W.salved && prob(2))
			W.disinfected = 1
			W.germ_level = 0

	// sync the organ's damage with its wounds
	src.update_damages()
	if(update_icon())
		owner.UpdateDamageIcon(src)

//Updates brute_damn and burn_damn from wound damages. Updates BLEEDING status.
/obj/item/organ/external/proc/update_damages()
	number_wounds = 0
	brute_dam = 0
	burn_dam = 0
	status &= ~ORGAN_BLEEDING
	var/clamped = 0
	for(var/datum/wound/W in wounds)
		if (!W.internal)
			if(W.damage_type == CUT || W.damage_type == BRUISE)
				brute_dam += W.damage
			else if(W.damage_type == BURN)
				burn_dam += W.damage

		if(!(status & ORGAN_ROBOT) && W.bleeding())
			W.bleed_timer--
			status |= ORGAN_BLEEDING

		clamped |= W.clamped

		number_wounds += W.amount

	if (open && !clamped)	//things tend to bleed if they are CUT OPEN
		status |= ORGAN_BLEEDING


// new damage icon system
// adjusted to set damage_state to brute/burn code only (without r_name0 as before)
/obj/item/organ/external/update_icon()
	var/n_is = damage_state_text()
	if(n_is != damage_state)
		damage_state = n_is
		return 1
	return 0

// new damage icon system
// returns just the brute/burn damage code
/obj/item/organ/external/proc/damage_state_text()
	if(status & ORGAN_DESTROYED)
		return "--"

	var/tburn = 0
	var/tbrute = 0

	if(burn_dam ==0)
		tburn =0
	else if (burn_dam < (max_damage * 0.25 / 2))
		tburn = 1
	else if (burn_dam < (max_damage * 0.75 / 2))
		tburn = 2
	else
		tburn = 3

	if (brute_dam == 0)
		tbrute = 0
	else if (brute_dam < (max_damage * 0.25 / 2))
		tbrute = 1
	else if (brute_dam < (max_damage * 0.75 / 2))
		tbrute = 2
	else
		tbrute = 3
	return "[tbrute][tburn]"

/****************************************************
			   DISMEMBERMENT
****************************************************/

//Recursive setting of all child bodyparts to amputated
/obj/item/organ/external/proc/setAmputatedTree()
	for(var/obj/item/organ/external/BP in children)
		BP.amputated = amputated
		BP.setAmputatedTree()

//Handles dismemberment
/obj/item/organ/external/proc/droplimb(override = 0,no_explode = 0)
	if(destspawn) return
	if(override)
		status |= ORGAN_DESTROYED
	for(var/datum/wound/W in wounds)
		if(W.internal)
			wounds -= W
			update_damages()
	if(status & ORGAN_DESTROYED)
		if(body_part == UPPER_TORSO)
			return

		src.status &= ~ORGAN_BROKEN
		src.status &= ~ORGAN_BLEEDING
		src.status &= ~ORGAN_SPLINTED
		for(var/implant in implants)
			qdel(implant)

		// If any bodyparts are attached to this, destroy them
		for(var/obj/item/organ/external/BP in owner.bodyparts)
			if(BP.parent == src)
				BP.droplimb(1)

		var/obj/bodypart	//Dropped limb object
		switch(body_part)
			if(HEAD)
				if(owner.species.flags[IS_SYNTHETIC])
					bodypart = new /obj/item/weapon/organ/head/posi(owner.loc, owner)
				else
					bodypart = new /obj/item/weapon/organ/head(owner.loc, owner)
				owner.u_equip(owner.glasses)
				owner.u_equip(owner.head)
				owner.u_equip(owner.l_ear)
				owner.u_equip(owner.r_ear)
				owner.u_equip(owner.wear_mask)
				if(istype(owner.wear_suit, /obj/item/clothing/suit/space/space_ninja)) //When ninja looses head, it does not go thru death() proc.
					var/obj/item/clothing/suit/space/space_ninja/my_suit = owner.wear_suit
					if(my_suit.s_initialized)
						spawn(30)
							if(owner)
								var/location = owner.loc
								explosion(location, 0, 0, 3, 4)
								owner.gib()
			if(ARM_RIGHT)
				if(status & ORGAN_ROBOT)
					bodypart = new /obj/item/robot_parts/r_arm(owner.loc)
				else
					bodypart = new /obj/item/weapon/organ/r_arm(owner.loc, owner)
			if(ARM_LEFT)
				if(status & ORGAN_ROBOT)
					bodypart = new /obj/item/robot_parts/l_arm(owner.loc)
				else
					bodypart = new /obj/item/weapon/organ/l_arm(owner.loc, owner)
			if(LEG_RIGHT)
				if(status & ORGAN_ROBOT)
					bodypart = new /obj/item/robot_parts/r_leg(owner.loc)
				else
					bodypart = new /obj/item/weapon/organ/r_leg(owner.loc, owner)
			if(LEG_LEFT)
				if(status & ORGAN_ROBOT)
					bodypart = new /obj/item/robot_parts/l_leg(owner.loc)
				else
					bodypart = new /obj/item/weapon/organ/l_leg(owner.loc, owner)
			if(HAND_RIGHT)
				if(!(status & ORGAN_ROBOT))
					bodypart = new /obj/item/weapon/organ/r_hand(owner.loc, owner)
				owner.u_equip(owner.gloves)
			if(HAND_LEFT)
				if(!(status & ORGAN_ROBOT))
					bodypart = new /obj/item/weapon/organ/l_hand(owner.loc, owner)
				owner.u_equip(owner.gloves)
			if(FOOT_RIGHT)
				if(!(status & ORGAN_ROBOT))
					bodypart = new /obj/item/weapon/organ/r_foot/(owner.loc, owner)
				owner.u_equip(owner.shoes)
			if(FOOT_LEFT)
				if(!(status & ORGAN_ROBOT))
					bodypart = new /obj/item/weapon/organ/l_foot(owner.loc, owner)
				owner.u_equip(owner.shoes)
		if(bodypart)
			destspawn = 1
			//Robotic limbs explode if sabotaged.
			if(status & ORGAN_ROBOT && !no_explode && sabotaged)
				owner.visible_message("\red \The [owner]'s [name] explodes violently!",\
				"\red <b>Your [name] explodes!</b>",\
				"You hear an explosion followed by a scream!")
				explosion(get_turf(owner),-1,-1,2,3)
				var/datum/effect/effect/system/spark_spread/spark_system = new /datum/effect/effect/system/spark_spread()
				spark_system.set_up(5, 0, owner)
				spark_system.attach(owner)
				spark_system.start()
				spawn(10)
					qdel(spark_system)

			owner.visible_message("\red [owner.name]'s [name] flies off in an arc.",\
			"<span class='moderate'><b>Your [name] goes flying off!</b></span>",\
			"You hear a terrible sound of ripping tendons and flesh.")

			//Throw bodypart around
			var/lol = pick(cardinal)
			step(bodypart, lol)

			owner.update_body()

			// OK so maybe your limb just flew off, but if it was attached to a pair of cuffs then hooray! Freedom!
			release_restraints()

			if(vital)
				owner.death()

		if(update_icon())
			owner.UpdateDamageIcon(src)

/****************************************************
			   HELPERS
****************************************************/

/obj/item/organ/external/proc/release_restraints()
	if (owner.handcuffed && body_part in list(ARM_LEFT, ARM_RIGHT, HAND_LEFT, HAND_RIGHT))
		owner.visible_message(\
			"\The [owner.handcuffed.name] falls off of [owner.name].",\
			"\The [owner.handcuffed.name] falls off you.")

		owner.drop_from_inventory(owner.handcuffed)

	if (owner.legcuffed && body_part in list(FOOT_LEFT, FOOT_RIGHT, LEG_LEFT, LEG_RIGHT))
		owner.visible_message(\
			"\The [owner.legcuffed.name] falls off of [owner.name].",\
			"\The [owner.legcuffed.name] falls off you.")

		owner.drop_from_inventory(owner.legcuffed)

// checks if all wounds on the organ are bandaged
/obj/item/organ/external/proc/is_bandaged()
	for(var/datum/wound/W in wounds)
		if(W.internal) continue
		if(!W.bandaged)
			return 0
	return 1

// checks if all wounds on the organ are salved
/obj/item/organ/external/proc/is_salved()
	for(var/datum/wound/W in wounds)
		if(W.internal) continue
		if(!W.salved)
			return 0
	return 1

// checks if all wounds on the organ are disinfected
/obj/item/organ/external/proc/is_disinfected()
	for(var/datum/wound/W in wounds)
		if(W.internal) continue
		if(!W.disinfected)
			return 0
	return 1

/obj/item/organ/external/proc/bandage()
	var/rval = 0
	src.status &= ~ORGAN_BLEEDING
	for(var/datum/wound/W in wounds)
		if(W.internal) continue
		rval |= !W.bandaged
		W.bandaged = 1
	return rval

/obj/item/organ/external/proc/disinfect()
	var/rval = 0
	for(var/datum/wound/W in wounds)
		if(W.internal) continue
		rval |= !W.disinfected
		W.disinfected = 1
		W.germ_level = 0
	return rval

/obj/item/organ/external/proc/clamp()
	var/rval = 0
	src.status &= ~ORGAN_BLEEDING
	for(var/datum/wound/W in wounds)
		if(W.internal) continue
		rval |= !W.clamped
		W.clamped = 1
	return rval

/obj/item/organ/external/proc/salve()
	var/rval = 0
	for(var/datum/wound/W in wounds)
		rval |= !W.salved
		W.salved = 1
	return rval

/obj/item/organ/external/proc/fracture()

	if(owner.dna && owner.dna.mutantrace == "adamantine")
		return

	if(status & ORGAN_BROKEN)
		return

	owner.visible_message(\
		"\red You hear a loud cracking sound coming from \the [owner].",\
		"\red <b>Something feels like it shattered in your [name]!</b>",\
		"You hear a sickening crack.")

	if(owner.species && !owner.species.flags[NO_PAIN])
		owner.emote("scream",,, 1)

	status |= ORGAN_BROKEN
	broken_description = pick("broken","fracture","hairline fracture")
	perma_injury = brute_dam

	// Fractures have a chance of getting you out of restraints
	if (prob(25))
		release_restraints()

	// This is mostly for the ninja suit to stop ninja being so crippled by breaks.
	// TODO: consider moving this to a suit proc or process() or something during
	// hardsuit rewrite.
	if(!(status & ORGAN_SPLINTED) && istype(owner,/mob/living/carbon/human))

		var/mob/living/carbon/human/H = owner

		if(H.wear_suit && istype(H.wear_suit,/obj/item/clothing/suit/space))

			var/obj/item/clothing/suit/space/suit = H.wear_suit

			if(isnull(suit.supporting_limbs))
				return

			to_chat(owner, "You feel \the [suit] constrict about your [name], supporting it.")
			status |= ORGAN_SPLINTED
			suit.supporting_limbs |= src
	return

/obj/item/organ/external/proc/robotize()
	src.status &= ~ORGAN_BROKEN
	src.status &= ~ORGAN_BLEEDING
	src.status &= ~ORGAN_SPLINTED
	src.status &= ~ORGAN_CUT_AWAY
	src.status &= ~ORGAN_ATTACHABLE
	src.status &= ~ORGAN_DESTROYED
	src.status |= ORGAN_ROBOT
	src.destspawn = 0
	for (var/obj/item/organ/external/BP in children)
		BP.robotize()

/obj/item/organ/external/proc/mutate()
	src.status |= ORGAN_MUTATED
	owner.update_body()

/obj/item/organ/external/proc/unmutate()
	src.status &= ~ORGAN_MUTATED
	owner.update_body()

/obj/item/organ/external/proc/get_damage()	//returns total damage
	return max(brute_dam + burn_dam - perma_injury, perma_injury)	//could use health?

/obj/item/organ/external/proc/has_infected_wound()
	for(var/datum/wound/W in wounds)
		if(W.germ_level > INFECTION_LEVEL_ONE)
			return 1
	return 0

/obj/item/organ/external/get_icon(icon/race_icon, icon/deform_icon,gender="",fat="")
	if (status & ORGAN_ROBOT && !(owner.species && owner.species.flags[IS_SYNTHETIC]))
		return new /icon('icons/mob/human_races/robotic.dmi', "[body_zone][gender ? "_[gender]" : ""]")

	if (status & ORGAN_MUTATED)
		return new /icon(deform_icon, "[body_zone][gender ? "_[gender]" : ""][fat ? "_[fat]" : ""]")

	return new /icon(race_icon, "[body_zone][gender ? "_[gender]" : ""][fat ? "_[fat]" : ""]")


/obj/item/organ/external/proc/is_usable()
	return !(status & (ORGAN_DESTROYED|ORGAN_MUTATED|ORGAN_DEAD))

/obj/item/organ/external/proc/is_broken()
	return ((status & ORGAN_BROKEN) && !(status & ORGAN_SPLINTED))

/obj/item/organ/external/proc/is_malfunctioning()
	return ((status & ORGAN_ROBOT) && prob(brute_dam + burn_dam))

//for arms and hands
/obj/item/organ/external/proc/process_grasp(obj/item/c_hand, hand_name)
	if (!c_hand)
		return

	if(is_broken())
		owner.drop_from_inventory(c_hand)
		var/emote_scream = pick("screams in pain and", "lets out a sharp cry and", "cries out and")
		owner.emote("me", 1, "[(owner.species && owner.species.flags[NO_PAIN]) ? "" : emote_scream ] drops what they were holding in their [hand_name]!")
	if(is_malfunctioning())
		owner.drop_from_inventory(c_hand)
		owner.emote("me", 1, "drops what they were holding, their [hand_name] malfunctioning!")
		var/datum/effect/effect/system/spark_spread/spark_system = new /datum/effect/effect/system/spark_spread()
		spark_system.set_up(5, 0, owner)
		spark_system.attach(owner)
		spark_system.start()
		spawn(10)
			qdel(spark_system)

/obj/item/organ/external/proc/embed(obj/item/weapon/W, silent = 0)
	if(!silent)
		owner.visible_message("<span class='danger'>\The [W] sticks in the wound!</span>")
	owner.throw_alert("embeddedobject")
	implants += W
	owner.embedded_flag = 1
	owner.verbs += /mob/proc/yank_out_object
	W.add_blood(owner)
	if(ismob(W.loc))
		var/mob/living/H = W.loc
		H.drop_item()
	W.loc = owner

/****************************************************
			   ORGAN DEFINES
****************************************************/

/obj/item/organ/external/chest
	name = "chest"

	body_part = UPPER_TORSO
	body_zone = BP_CHEST
	limb_layer = LIMB_TORSO_LAYER

	max_damage = 75
	min_broken_damage = 40
	vital = 1


/obj/item/organ/external/groin
	name = "groin"

	body_part = LOWER_TORSO
	body_zone = BP_GROIN
	parent_bodypart = BP_CHEST
	limb_layer = LIMB_GROIN_LAYER

	max_damage = 50
	min_broken_damage = 30
	vital = 1


/obj/item/organ/external/head
	name = "head"

	body_part = HEAD
	body_zone = BP_HEAD
	parent_bodypart = BP_CHEST
	limb_layer = LIMB_HEAD_LAYER

	max_damage = 75
	min_broken_damage = 40
	vital = 1

	var/disfigured = 0


/obj/item/organ/external/l_arm
	name = "left arm"

	body_part = ARM_LEFT
	body_zone = BP_L_ARM
	parent_bodypart = BP_CHEST
	limb_layer = LIMB_L_ARM_LAYER

	max_damage = 50
	min_broken_damage = 20

/obj/item/organ/external/l_arm/process()
	..()
	process_grasp(owner.l_hand, "left hand")


/obj/item/organ/external/r_arm
	name = "right arm"

	body_part = ARM_RIGHT
	body_zone = BP_R_ARM
	parent_bodypart = BP_CHEST
	limb_layer = LIMB_R_ARM_LAYER

	max_damage = 50
	min_broken_damage = 20

/obj/item/organ/external/r_arm/process()
	..()
	process_grasp(owner.r_hand, "right hand")


/obj/item/organ/external/l_hand
	name = "left hand"

	body_part = HAND_LEFT
	body_zone = BP_L_HAND
	parent_bodypart = BP_L_ARM
	limb_layer = LIMB_L_HAND_LAYER

	max_damage = 30
	min_broken_damage = 15

/obj/item/organ/external/l_hand/process()
	..()
	process_grasp(owner.l_hand, "left hand")


/obj/item/organ/external/r_hand
	name = "right hand"

	body_part = HAND_RIGHT
	body_zone = BP_R_HAND
	parent_bodypart = BP_R_ARM
	limb_layer = LIMB_R_HAND_LAYER

	max_damage = 30
	min_broken_damage = 15

/obj/item/organ/external/r_hand/process()
	..()
	process_grasp(owner.r_hand, "right hand")


/obj/item/organ/external/l_leg
	name = "left leg"

	body_part = LEG_LEFT
	body_zone = BP_L_LEG
	parent_bodypart = BP_CHEST
	limb_layer = LIMB_L_LEG_LAYER
	icon_position = LEFT

	max_damage = 50
	min_broken_damage = 20


/obj/item/organ/external/r_leg
	name = "right leg"

	body_part = LEG_RIGHT
	body_zone = BP_R_LEG
	parent_bodypart = BP_CHEST
	limb_layer = LIMB_R_LEG_LAYER
	icon_position = RIGHT

	max_damage = 50
	min_broken_damage = 20


/obj/item/organ/external/l_foot
	name = "left foot"

	body_part = FOOT_LEFT
	body_zone = BP_L_FOOT
	parent_bodypart = BP_L_LEG
	limb_layer = LIMB_L_FOOT_LAYER
	icon_position = LEFT

	max_damage = 30
	min_broken_damage = 15


/obj/item/organ/external/r_foot
	name = "right foot"

	body_part = FOOT_RIGHT
	body_zone = BP_R_FOOT
	parent_bodypart = BP_R_LEG
	limb_layer = LIMB_R_FOOT_LAYER
	icon_position = RIGHT

	max_damage = 30
	min_broken_damage = 15


/obj/item/organ/external/head/get_icon(icon/race_icon, icon/deform_icon)
	if (!owner)
		return ..()
	var/g = "m"
	if(owner.gender == FEMALE)
		g = "f"
	if(status & ORGAN_MUTATED)
		. = new /icon(deform_icon, "[body_zone]_[g]")
	else
		. = new /icon(race_icon, "[body_zone]_[g]")

/obj/item/organ/external/head/take_damage(brute, burn, sharp, edge, used_weapon = null, list/forbidden_limbs = list())
	. = ..(brute, burn, sharp, edge, used_weapon, forbidden_limbs)
	if(!disfigured)
		if(brute_dam > 40)
			if (prob(50))
				disfigure("brute")
		if(burn_dam > 40)
			disfigure("burn")

/obj/item/organ/external/head/proc/disfigure(type = "brute")
	if (disfigured)
		return
	if(type == "brute")
		owner.visible_message("\red You hear a sickening cracking sound coming from \the [owner]'s face.",	\
		"\red <b>Your face becomes unrecognizible mangled mess!</b>",	\
		"\red You hear a sickening crack.")
	else
		owner.visible_message("\red [owner]'s face melts away, turning into mangled mess!",	\
		"\red <b>Your face melts off!</b>",	\
		"\red You hear a sickening sizzle.")
	disfigured = 1

/****************************************************
			   EXTERNAL ORGAN ITEMS
****************************************************/

/obj/item/weapon/organ
	icon = 'icons/mob/human_races/r_human.dmi'

/obj/item/weapon/organ/New(loc, mob/living/carbon/human/H)
	..(loc)
	if(!istype(H))
		return
	if(H.dna)
		if(!blood_DNA)
			blood_DNA = list()
		blood_DNA[H.dna.unique_enzymes] = H.dna.b_type

	//Forming icon for the limb

	//Setting base icon for this mob's race
	var/icon/base
	if(H.species && H.species.icobase)
		base = icon(H.species.icobase)
	else
		base = icon('icons/mob/human_races/r_human.dmi')

	if(base)
		//Changing limb's skin tone to match owner
		if(!H.species || H.species.flags[HAS_SKIN_TONE])
			if (H.s_tone >= 0)
				base.Blend(rgb(H.s_tone, H.s_tone, H.s_tone), ICON_ADD)
			else
				base.Blend(rgb(-H.s_tone,  -H.s_tone,  -H.s_tone), ICON_SUBTRACT)

	if(base)
		//Changing limb's skin color to match owner
		if(!H.species || H.species.flags[HAS_SKIN_COLOR])
			base.Blend(rgb(H.r_skin, H.g_skin, H.b_skin), ICON_ADD)

	icon = base
	dir = SOUTH
	src.transform = turn(src.transform, rand(70,130))


/****************************************************
			   EXTERNAL ORGAN ITEMS DEFINES
****************************************************/
/obj/item/weapon/organ/l_arm
	name = "left arm"
	icon_state = BP_L_ARM
/obj/item/weapon/organ/l_foot
	name = "left foot"
	icon_state = BP_L_FOOT
/obj/item/weapon/organ/l_hand
	name = "left hand"
	icon_state = BP_L_HAND
/obj/item/weapon/organ/l_leg
	name = "left leg"
	icon_state = BP_L_LEG
/obj/item/weapon/organ/r_arm
	name = "right arm"
	icon_state = BP_R_ARM
/obj/item/weapon/organ/r_foot
	name = "right foot"
	icon_state = BP_R_FOOT
/obj/item/weapon/organ/r_hand
	name = "right hand"
	icon_state = BP_R_HAND
/obj/item/weapon/organ/r_leg
	name = "right leg"
	icon_state = BP_R_LEG
/obj/item/weapon/organ/head
	name = "head"
	icon_state = BP_HEAD
	var/mob/living/carbon/brain/brainmob
	var/brain_op_stage = 0

/obj/item/weapon/organ/head/posi
	name = "robotic head"

/obj/item/weapon/organ/head/New(loc, mob/living/carbon/human/H)
	if(istype(H))
		src.icon_state = H.gender == MALE? "head_m" : "head_f"
	..()
	//Add (facial) hair.
	if(H.f_style)
		var/datum/sprite_accessory/facial_hair_style = facial_hair_styles_list[H.f_style]
		if(facial_hair_style)
			var/image/facial = image("icon" = facial_hair_style.icon, "icon_state" = "[facial_hair_style.icon_state]_s")
			if(facial_hair_style.do_colouration)
				facial.color = rgb(H.r_facial, H.g_facial, H.b_facial)

			overlays.Add(facial) // icon.Blend(facial, ICON_OVERLAY)

	if(H.h_style && !(H.head && (H.head.flags & BLOCKHEADHAIR)))
		var/datum/sprite_accessory/hair_style = hair_styles_list[H.h_style]
		if(hair_style)
			var/image/hair = image("icon" = hair_style.icon, "icon_state" = "[hair_style.icon_state]_s")
			if(hair_style.do_colouration)
				hair.color = rgb(H.r_hair, H.g_hair, H.b_hair)

			overlays.Add(hair) //icon.Blend(hair, ICON_OVERLAY)
	spawn(5)
	if(brainmob && brainmob.client)
		brainmob.client.screen.len = null //clear the hud

	//if(ishuman(H))
	//	if(H.gender == FEMALE)
	//		H.icon_state = "head_f"
	transfer_identity(H)

	name = "[H.real_name]'s head"

	H.regenerate_icons()

	H.stat = DEAD
	H.death()
	brainmob.stat = DEAD
	brainmob.death()
	if(brainmob && brainmob.mind && brainmob.mind.changeling) //cuz fuck runtimes
		var/datum/changeling/Host = brainmob.mind.changeling
		if(Host.chem_charges >= 35 && Host.geneticdamage < 10)
			for(var/obj/effect/proc_holder/changeling/headcrab/crab in Host.purchasedpowers)
				if(istype(crab))
					crab.sting_action(brainmob)
					H.gib()
/obj/item/weapon/organ/head/proc/transfer_identity(mob/living/carbon/human/H)//Same deal as the regular brain proc. Used for human-->head
	brainmob = new(src)
	brainmob.name = H.real_name
	brainmob.real_name = H.real_name
	brainmob.dna = H.dna.Clone()
	if(H.mind)
		H.mind.transfer_to(brainmob)
	brainmob.container = src

/obj/item/weapon/organ/head/attackby(obj/item/weapon/W, mob/user)
	if(istype(W,/obj/item/weapon/scalpel))
		switch(brain_op_stage)
			if(0)
				for(var/mob/O in (oviewers(brainmob) - user))
					O.show_message("\red [brainmob] is beginning to have \his head cut open with [W] by [user].", 1)
				to_chat(brainmob, "\red [user] begins to cut open your head with [W]!")
				to_chat(user, "\red You cut [brainmob]'s head open with [W]!")

				brain_op_stage = 1

			if(2)
				for(var/mob/O in (oviewers(brainmob) - user))
					O.show_message("\red [brainmob] is having \his connections to the brain delicately severed with [W] by [user].", 1)
				to_chat(brainmob, "\red [user] begins to cut open your head with [W]!")
				to_chat(user, "\red You cut [brainmob]'s head open with [W]!")

				brain_op_stage = 3.0
			else
				..()
	else if(istype(W,/obj/item/weapon/circular_saw))
		switch(brain_op_stage)
			if(1)
				for(var/mob/O in (oviewers(brainmob) - user))
					O.show_message("\red [brainmob] has \his head sawed open with [W] by [user].", 1)
				to_chat(brainmob, "\red [user] begins to saw open your head with [W]!")
				to_chat(user, "\red You saw [brainmob]'s head open with [W]!")

				brain_op_stage = 2
			if(3)
				for(var/mob/O in (oviewers(brainmob) - user))
					O.show_message("\red [brainmob] has \his spine's connection to the brain severed with [W] by [user].", 1)
				to_chat(brainmob, "\red [user] severs your brain's connection to the spine with [W]!")
				to_chat(user, "\red You sever [brainmob]'s brain's connection to the spine with [W]!")

				user.attack_log += "\[[time_stamp()]\]<font color='red'> Debrained [brainmob.name] ([brainmob.ckey]) with [W.name] (INTENT: [uppertext(user.a_intent)])</font>"
				brainmob.attack_log += "\[[time_stamp()]\]<font color='orange'> Debrained by [user.name] ([user.ckey]) with [W.name] (INTENT: [uppertext(user.a_intent)])</font>"
				msg_admin_attack("[user.name] ([user.ckey]) debrained [brainmob.name] ([brainmob.ckey]) (INTENT: [uppertext(user.a_intent)]) (<A HREF='?_src_=holder;adminplayerobservecoodjump=1;X=[user.x];Y=[user.y];Z=[user.z]'>JMP</a>)")

				if(istype(src,/obj/item/weapon/organ/head/posi))
					var/obj/item/device/mmi/posibrain/B = new(loc)
					B.transfer_identity(brainmob)
				else
					var/obj/item/brain/B = new(loc)
					B.transfer_identity(brainmob)

				brain_op_stage = 4.0
			else
				..()
	else
		..()

/obj/item/organ/external/proc/get_wounds_desc()
	if(status == ORGAN_ROBOT)
		var/list/descriptors = list()
		if(brute_dam)
			switch(brute_dam)
				if(0 to 20)
					descriptors += "some dents"
				if(21 to INFINITY)
					descriptors += pick("a lot of dents","severe denting")
		if(burn_dam)
			switch(burn_dam)
				if(0 to 20)
					descriptors += "some burns"
				if(21 to INFINITY)
					descriptors += pick("a lot of burns","severe melting")
		if(open)
			descriptors += "an open panel"

		return english_list(descriptors)

	var/list/flavor_text = list()
	if(status & ORGAN_DESTROYED)
		flavor_text += "a tear and hangs by a scrap of flesh" // TODO ZAKONCHIT'

	var/list/wound_descriptors = list()
	if(open > 1)
		wound_descriptors["an open incision"] = 1
	else if (open)
		wound_descriptors["an incision"] = 1
	for(var/datum/wound/W in wounds)
		if(W.internal && !open) continue // can't see internal wounds
		var/this_wound_desc = W.desc

		if(W.damage_type == BURN && W.salved)
			this_wound_desc = "salved [this_wound_desc]"

		if(W.bleeding())
			this_wound_desc = "bleeding [this_wound_desc]"
		else if(W.bandaged)
			this_wound_desc = "bandaged [this_wound_desc]"

		if(W.germ_level > 600)
			this_wound_desc = "badly infected [this_wound_desc]"
		else if(W.germ_level > 330)
			this_wound_desc = "lightly infected [this_wound_desc]"

		if(wound_descriptors[this_wound_desc])
			wound_descriptors[this_wound_desc] += W.amount
		else
			wound_descriptors[this_wound_desc] = W.amount

	for(var/wound in wound_descriptors)
		switch(wound_descriptors[wound])
			if(1)
				flavor_text += "a [wound]"
			if(2)
				flavor_text += "a pair of [wound]s"
			if(3 to 5)
				flavor_text += "several [wound]s"
			if(6 to INFINITY)
				flavor_text += "a ton of [wound]\s"

	return english_list(flavor_text)
