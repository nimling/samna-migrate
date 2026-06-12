CREATE OR REPLACE FUNCTION filter_by_schedule_rules(
    merged_rules JSONB,
    query_result REFCURSOR
)
    RETURNS SETOF RECORD AS
$$
DECLARE
    result_record RECORD;
    rule_matches  BOOLEAN;
BEGIN
    -- Fetch records from the cursor
    LOOP
        FETCH query_result INTO result_record;
        EXIT WHEN NOT FOUND;

        -- Check if record matches any rule
        rule_matches := EXISTS (SELECT 1
                                FROM jsonb_array_elements(merged_rules) AS rule_json
                                WHERE check_record_matches_rule(result_record, rule_json));

        -- Return record if it matches a rule
        IF rule_matches THEN
            RETURN NEXT result_record;
        END IF;
    END LOOP;

    RETURN;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_record_matches_rule(
    record_row RECORD,
    rule_json JSONB
)
    RETURNS BOOLEAN AS
$$
DECLARE
    schedule_json   JSONB;
    pattern_json    JSONB;
    pattern_type    TEXT;
    interval_val    INT;
    start_date      TIMESTAMP WITH TIME ZONE;
    end_date        TIMESTAMP WITH TIME ZONE;
    count_val       INT;
    record_start_at TIMESTAMP WITH TIME ZONE;
    record_end_at   TIMESTAMP WITH TIME ZONE;
    timezone_name   TEXT;
    iterations      INT;
BEGIN
    -- Extract start_at and end_at from record
    IF record_row.start_at IS NULL THEN
        RETURN FALSE; -- Cannot process without start_at
    END IF;

    record_start_at := record_row.start_at;
    record_end_at := COALESCE(record_row.end_at, record_start_at);

    -- Extract schedule and pattern
    schedule_json := rule_json -> 'schedule';
    pattern_json := schedule_json -> 'pattern';
    pattern_type := pattern_json ->> 'type';
    interval_val := (pattern_json ->> 'interval')::INT;
    start_date := (schedule_json ->> 'start_date')::TIMESTAMP WITH TIME ZONE;

    -- Exit early if record is before start_date
    IF record_end_at < start_date THEN
        RETURN FALSE;
    END IF;

    -- Check end_date if present
    IF schedule_json ->> 'end_date' IS NOT NULL THEN
        end_date := (schedule_json ->> 'end_date')::TIMESTAMP WITH TIME ZONE;
        IF record_start_at > end_date THEN
            RETURN FALSE;
        END IF;
    END IF;

    -- Apply timezone if specified
    IF schedule_json ->> 'time_zone' IS NOT NULL THEN
        timezone_name := schedule_json ->> 'time_zone';
        start_date := start_date AT TIME ZONE timezone_name;
        record_start_at := record_start_at AT TIME ZONE timezone_name;
        record_end_at := record_end_at AT TIME ZONE timezone_name;
    END IF;

    -- Check count if present
    IF pattern_json ->> 'count' IS NOT NULL THEN
        count_val := (pattern_json ->> 'count')::INT;
    ELSE
        count_val := NULL;
    END IF;

    -- Check recurrence pattern type
    IF NOT check_recurrence_pattern(record_start_at, start_date, pattern_type, interval_val, count_val) THEN
        RETURN FALSE;
    END IF;

    -- Check frequency constraints
    -- Days of week
    IF jsonb_typeof(pattern_json -> 'days_of_week') = 'array' AND
       NOT check_days_of_week(record_start_at, pattern_json -> 'days_of_week') THEN
        RETURN FALSE;
    END IF;

    -- Days of month
    IF jsonb_typeof(pattern_json -> 'days_of_month') = 'array' AND
       NOT check_days_of_month(record_start_at, pattern_json -> 'days_of_month') THEN
        RETURN FALSE;
    END IF;

    -- Weeks of month
    IF jsonb_typeof(pattern_json -> 'weeks_of_month') = 'array' AND
       NOT check_weeks_of_month(record_start_at, pattern_json -> 'weeks_of_month') THEN
        RETURN FALSE;
    END IF;

    -- Months of year
    IF jsonb_typeof(pattern_json -> 'months_of_year') = 'array' AND
       NOT check_months_of_year(record_start_at, pattern_json -> 'months_of_year') THEN
        RETURN FALSE;
    END IF;

    -- Days of year
    IF jsonb_typeof(pattern_json -> 'days_of_year') = 'array' AND
       NOT check_days_of_year(record_start_at, pattern_json -> 'days_of_year') THEN
        RETURN FALSE;
    END IF;

    -- If we've made it here, the record matches the rule
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_recurrence_pattern(
    record_date TIMESTAMP WITH TIME ZONE,
    start_date TIMESTAMP WITH TIME ZONE,
    pattern_type TEXT,
    interval_val INT,
    count_val INT
)
    RETURNS BOOLEAN AS
$$
DECLARE
    days_between   INT;
    weeks_between  INT;
    months_between INT;
    years_between  INT;
    iterations     INT;
BEGIN
    CASE pattern_type
        WHEN 'daily' THEN days_between := EXTRACT(EPOCH FROM (record_date - start_date)) / 86400;
                          IF days_between < 0 THEN
                              RETURN FALSE;
                          END IF;
                          iterations := days_between / interval_val;
                          IF count_val IS NOT NULL AND iterations >= count_val THEN
                              RETURN FALSE;
                          END IF;
                          RETURN days_between % interval_val = 0;

        WHEN 'weekly' THEN weeks_between := FLOOR(EXTRACT(EPOCH FROM (record_date - start_date)) / (86400 * 7)) + 1;
                           IF weeks_between < 1 THEN
                               RETURN FALSE;
                           END IF;
                           iterations := (weeks_between - 1) / interval_val;
                           IF count_val IS NOT NULL AND iterations >= count_val THEN
                               RETURN FALSE;
                           END IF;
                           RETURN (weeks_between - 1) % interval_val = 0;

        WHEN 'monthly' THEN months_between := (EXTRACT(YEAR FROM record_date) - EXTRACT(YEAR FROM start_date)) * 12 +
                                              (EXTRACT(MONTH FROM record_date) - EXTRACT(MONTH FROM start_date)) + 1;
                            IF months_between < 0 THEN
                                RETURN FALSE;
                            END IF;
                            iterations := months_between / interval_val;
                            IF count_val IS NOT NULL AND iterations >= count_val THEN
                                RETURN FALSE;
                            END IF;
                            RETURN months_between % interval_val = 0;

        WHEN 'yearly' THEN years_between := (EXTRACT(YEAR FROM record_date) - EXTRACT(YEAR FROM start_date)) + 1;
                           IF years_between < 0 THEN
                               RETURN FALSE;
                           END IF;
                           iterations := years_between / interval_val;
                           IF count_val IS NOT NULL AND iterations >= count_val THEN
                               RETURN FALSE;
                           END IF;
                           RETURN years_between % interval_val = 0;

        ELSE RETURN FALSE;
        END CASE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_days_of_week(
    dt TIMESTAMP WITH TIME ZONE,
    days_json JSONB
)
    RETURNS BOOLEAN AS
$$
DECLARE
    dow     INT;
    day_val INT;
BEGIN
    IF days_json IS NULL OR jsonb_typeof(days_json) <> 'array' THEN
        RETURN FALSE;
    END IF;

    dow := EXTRACT(DOW FROM dt);

    FOR day_val IN SELECT jsonb_array_elements_text(days_json)::INT
        LOOP
            IF day_val < 0 THEN
                day_val := 7 + day_val; -- Convert negative to 0-6 range
            END IF;

            day_val := day_val % 7;
            IF dow = day_val THEN
                RETURN TRUE;
            END IF;
        END LOOP;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_days_of_month(
    dt TIMESTAMP WITH TIME ZONE,
    days_json JSONB
)
    RETURNS BOOLEAN AS
$$
DECLARE
    day_of_month INT;
    day_val      INT;
    last_day     INT;
BEGIN
    IF days_json IS NULL OR jsonb_typeof(days_json) <> 'array' THEN
        RETURN FALSE;
    END IF;

    day_of_month := EXTRACT(DAY FROM dt);

    FOR day_val IN SELECT jsonb_array_elements_text(days_json)::INT
        LOOP
            IF day_val < 0 THEN
                last_day := EXTRACT(DAY FROM
                                    (DATE_TRUNC('MONTH', dt) + INTERVAL '1 MONTH - 1 day')::DATE
                            );
                day_val := last_day + day_val + 1;
            END IF;

            IF day_of_month = day_val THEN
                RETURN TRUE;
            END IF;
        END LOOP;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_weeks_of_month(
    dt TIMESTAMP WITH TIME ZONE,
    weeks_json JSONB
)
    RETURNS BOOLEAN AS
$$
DECLARE
    day_of_month  INT;
    week_of_month INT;
    week_val      INT;
    last_day      INT;
    last_week     INT;
BEGIN
    IF weeks_json IS NULL OR jsonb_typeof(weeks_json) <> 'array' THEN
        RETURN FALSE;
    END IF;

    day_of_month := EXTRACT(DAY FROM dt);
    week_of_month := (day_of_month - 1) / 7 + 1;

    FOR week_val IN SELECT jsonb_array_elements_text(weeks_json)::INT
        LOOP
            IF week_val < 0 THEN
                last_day := EXTRACT(DAY FROM
                                    (DATE_TRUNC('MONTH', dt) + INTERVAL '1 MONTH - 1 day')::DATE
                            );
                last_week := (last_day - 1) / 7 + 1;
                week_val := last_week + week_val + 1;
            END IF;

            IF week_of_month = week_val THEN
                RETURN TRUE;
            END IF;
        END LOOP;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_months_of_year(
    dt TIMESTAMP WITH TIME ZONE,
    months_json JSONB
)
    RETURNS BOOLEAN AS
$$
DECLARE
    month_of_year INT;
    month_val     INT;
BEGIN
    IF months_json IS NULL OR jsonb_typeof(months_json) <> 'array' THEN
        RETURN FALSE;
    END IF;

    month_of_year := EXTRACT(MONTH FROM dt);

    FOR month_val IN SELECT jsonb_array_elements_text(months_json)::INT
        LOOP
            IF month_val < 0 THEN
                month_val := 12 + month_val + 1;
            END IF;

            IF month_of_year = month_val THEN
                RETURN TRUE;
            END IF;
        END LOOP;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_days_of_year(
    dt TIMESTAMP WITH TIME ZONE,
    days_json JSONB
)
    RETURNS BOOLEAN AS
$$
DECLARE
    day_of_year INT;
    day_val     INT;
    last_day    INT;
BEGIN
    IF days_json IS NULL OR jsonb_typeof(days_json) <> 'array' THEN
        RETURN FALSE;
    END IF;

    day_of_year := EXTRACT(DOY FROM dt);

    FOR day_val IN SELECT jsonb_array_elements_text(days_json)::INT
        LOOP
            IF day_val < 0 THEN
                last_day := EXTRACT(DOY FROM
                                    (DATE_TRUNC('YEAR', dt) + INTERVAL '1 YEAR - 1 day')::DATE
                            );
                day_val := last_day + day_val + 1;
            END IF;

            IF day_of_year = day_val THEN
                RETURN TRUE;
            END IF;
        END LOOP;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_next_occurrence(
    schedule jsonb, 
    from_time timestamptz DEFAULT NOW(),
    OUT next_start timestamptz,
    OUT next_end timestamptz
) AS $$
DECLARE
    start_date timestamptz;
    end_date timestamptz;
    patterns jsonb;
    pattern jsonb;
    recurrence_type text;
    interval_val integer;
    days_of_week text[];
    end_recurrence timestamptz;
    next_start_candidate timestamptz;
    next_end_candidate timestamptz;
    duration interval;
    pattern_idx integer;
    times_json jsonb;
    time_str text;
    time_parts text[];
    time_part text;
    duration_part text;
    start_time_str text;
    duration_hours integer;
    duration_minutes integer;
    pattern_start_time time;
BEGIN
    -- Default return values (no occurrence found)
    next_start := NULL;
    next_end := NULL;

    -- Extract schedule components
    start_date := (schedule->>'start_date')::timestamptz;
    
    IF schedule->>'end_date' IS NOT NULL THEN
        end_date := (schedule->>'end_date')::timestamptz;
    END IF;
    
    IF schedule->>'end_recurrence' IS NOT NULL THEN
        end_recurrence := (schedule->>'end_recurrence')::timestamptz;
    END IF;
    
    pattern := schedule->'pattern';
    
    -- ISSUE: Time zone handling - the schedule might have a time_zone field that we're not applying here
    -- We should convert start_date, end_date, from_time to the schedule's timezone if specified
    
    -- Extract times from pattern and parse duration
    times_json := pattern->'times';
    IF times_json IS NOT NULL THEN
        time_str := times_json->>0;
        IF time_str IS NOT NULL THEN
            time_parts := string_to_array(time_str, '/');
            
            IF array_length(time_parts, 1) >= 2 THEN
                start_time_str := time_parts[1];
                duration_part := time_parts[2];
                
                -- Parse start time (HH:MM format)
                pattern_start_time := start_time_str::time;
                
                -- Parse PT2H30M format for duration
                duration_hours := 0;
                duration_minutes := 0;
                
                -- Extract hours if present
                IF duration_part ~ 'PT\d+H' THEN
                    duration_hours := (regexp_matches(duration_part, 'PT(\d+)H'))[1]::INT;
                END IF;
                
                -- Extract minutes if present  
                IF duration_part ~ '\d+M' THEN
                    duration_minutes := (regexp_matches(duration_part, '(\d+)M'))[1]::INT;
                END IF;
                
                duration := (duration_hours || ' hours ' || duration_minutes || ' minutes')::interval;
            ELSE
                -- Fallback to simple time format
                pattern_start_time := time_str::time;
                duration := INTERVAL '1 hour';
            END IF;
        ELSE
            -- No times specified, use schedule dates
            IF schedule->>'end_date' IS NOT NULL THEN
                duration := end_date - start_date;
            ELSE
                duration := INTERVAL '1 hour';
            END IF;
            pattern_start_time := start_date::time;
        END IF;
    ELSE
        -- Fallback to schedule dates if no times specified
        IF schedule->>'end_date' IS NOT NULL THEN
            duration := end_date - start_date;
        ELSE
            duration := INTERVAL '1 hour';
        END IF;
        pattern_start_time := start_date::time;
    END IF;
    
    -- If the schedule has a start date in the future, use that date with the pattern time
    IF start_date > from_time THEN
        next_start := date_trunc('day', start_date) + 
                     EXTRACT(HOUR FROM pattern_start_time) * INTERVAL '1 hour' +
                     EXTRACT(MINUTE FROM pattern_start_time) * INTERVAL '1 minute' +
                     EXTRACT(SECOND FROM pattern_start_time) * INTERVAL '1 second';
        next_end := next_start + duration;
        RETURN;
    END IF;
    
    -- If no pattern, there's no recurrence
    IF pattern IS NULL THEN
        RETURN;
    END IF;
    
    -- Process the single pattern
    recurrence_type := pattern->>'type';
    
    -- Extract common pattern properties
    IF pattern->>'interval' IS NOT NULL THEN
        interval_val := (pattern->>'interval')::integer;
        IF interval_val <= 0 THEN
            interval_val := 1; -- Default to 1 if invalid
        END IF;
    ELSE
        interval_val := 1; -- Default interval
    END IF;
    
    -- Calculate next occurrence based on recurrence type
    CASE recurrence_type
            WHEN 'daily' THEN
                -- Calculate days since start
                DECLARE
                    days_since_start integer;
                    days_to_add integer;
                BEGIN
                    days_since_start := EXTRACT(EPOCH FROM (from_time - start_date)) / 86400;
                    days_to_add := interval_val - (days_since_start % interval_val);
                    
                    -- If we're on a valid day but before the time of day, use today
                    IF days_to_add = interval_val AND 
                       (EXTRACT(HOUR FROM from_time) < EXTRACT(HOUR FROM pattern_start_time) OR 
                        (EXTRACT(HOUR FROM from_time) = EXTRACT(HOUR FROM pattern_start_time) AND 
                         EXTRACT(MINUTE FROM from_time) < EXTRACT(MINUTE FROM pattern_start_time))) THEN
                        days_to_add := 0;
                    END IF;
                    
                    next_start_candidate := date_trunc('day', from_time) + 
                                            (days_to_add || ' days')::interval +
                                            EXTRACT(HOUR FROM pattern_start_time) * INTERVAL '1 hour' +
                                            EXTRACT(MINUTE FROM pattern_start_time) * INTERVAL '1 minute' +
                                            EXTRACT(SECOND FROM pattern_start_time) * INTERVAL '1 second';
                    next_end_candidate := next_start_candidate + duration;
                END;
                
            WHEN 'weekly' THEN
                -- ISSUE: Days of week handling uses string comparison with to_char() which is locale-dependent
                -- Should use numeric day-of-week values (0-6) consistently
                
                -- Extract days of week from pattern
                IF pattern->'days_of_week' IS NOT NULL AND jsonb_array_length(pattern->'days_of_week') > 0 THEN
                    SELECT array_agg(day::text)
                    INTO days_of_week
                    FROM jsonb_array_elements_text(pattern->'days_of_week') day;
                ELSE
                    -- Default to the day of week of the start date
                    days_of_week := ARRAY[to_char(start_date, 'Day')];
                END IF;
                
                DECLARE
                    weeks_since_start integer;
                    next_week_number integer;
                    current_interval integer;
                    days_to_add integer;
                    current_day text;
                    check_date date;
                    found boolean := false;
                BEGIN
                    -- Use NimCal's weekly calculation: weeks_elapsed = floor((target - start) / 604800) + 1
                    
                    -- Calculate weeks elapsed since start (NimCal formula)
                    weeks_since_start := FLOOR(EXTRACT(EPOCH FROM (from_time - start_date)) / (86400 * 7)) + 1;
                    
                    -- Find the next valid week based on interval
                    IF weeks_since_start < 1 THEN
                        next_week_number := 1;
                    ELSE
                        -- Calculate which interval we're in
                        current_interval := FLOOR((weeks_since_start - 1) / interval_val);
                        
                        -- Check if current week matches the pattern
                        IF (weeks_since_start - 1) % interval_val = 0 THEN
                            next_week_number := weeks_since_start;
                        ELSE
                            -- Move to next valid interval
                            next_week_number := (current_interval + 1) * interval_val + 1;
                        END IF;
                    END IF;
                    
                    -- Calculate the target week based on NimCal logic
                    -- Target week should be: start_date + (next_week_number - 1) * 7 days
                    check_date := (start_date + ((next_week_number - 1) * 7 || ' days')::interval)::date;
                    
                    -- Find the correct day of week in that target week
                    FOR i IN 0..6 LOOP
                        check_date := (start_date + ((next_week_number - 1) * 7 + i || ' days')::interval)::date;
                        
                        -- Check if this day matches any of the allowed days of week
                        IF EXTRACT(DOW FROM check_date)::integer::text = ANY(days_of_week) THEN
                            next_start_candidate := date_trunc('day', check_date) +
                                                   EXTRACT(HOUR FROM pattern_start_time) * INTERVAL '1 hour' +
                                                   EXTRACT(MINUTE FROM pattern_start_time) * INTERVAL '1 minute' +
                                                   EXTRACT(SECOND FROM pattern_start_time) * INTERVAL '1 second';
                            
                            -- Ensure it's in the future
                            IF next_start_candidate > from_time THEN
                                found := true;
                                EXIT;
                            END IF;
                        END IF;
                    END LOOP;
                    
                    -- If still not found, try the next interval
                    IF NOT found THEN
                        next_week_number := next_week_number + interval_val;
                        
                        -- Find first valid day in the next interval
                        FOR i IN 0..6 LOOP
                            check_date := (start_date + ((next_week_number - 1) * 7 + i || ' days')::interval)::date;
                            
                            IF EXTRACT(DOW FROM check_date)::integer::text = ANY(days_of_week) THEN
                                next_start_candidate := date_trunc('day', check_date) +
                                                      EXTRACT(HOUR FROM pattern_start_time) * INTERVAL '1 hour' +
                                                      EXTRACT(MINUTE FROM pattern_start_time) * INTERVAL '1 minute' +
                                                      EXTRACT(SECOND FROM pattern_start_time) * INTERVAL '1 second';
                                found := true;
                                EXIT;
                            END IF;
                        END LOOP;
                    END IF;
                    
                    IF found THEN
                        next_end_candidate := next_start_candidate + duration;
                    END IF;
                END;
                
            WHEN 'monthly' THEN
                DECLARE
                    months_since_start integer;
                    months_to_add integer;
                    next_month_date date;
                    day_of_month integer;
                BEGIN
                    -- Calculate months since start
                    months_since_start := (EXTRACT(YEAR FROM from_time) - EXTRACT(YEAR FROM start_date)) * 12 +
                                          (EXTRACT(MONTH FROM from_time) - EXTRACT(MONTH FROM start_date));
                    
                    -- Calculate next month based on interval
                    months_to_add := interval_val - (months_since_start % interval_val);
                    
                    -- If we're in a valid month but before the day/time, use current month
                    IF months_to_add = interval_val AND 
                       (EXTRACT(DAY FROM from_time) < EXTRACT(DAY FROM start_date) OR
                        (EXTRACT(DAY FROM from_time) = EXTRACT(DAY FROM start_date) AND
                         (EXTRACT(HOUR FROM from_time) < EXTRACT(HOUR FROM pattern_start_time) OR
                          (EXTRACT(HOUR FROM from_time) = EXTRACT(HOUR FROM pattern_start_time) AND
                           EXTRACT(MINUTE FROM from_time) < EXTRACT(MINUTE FROM pattern_start_time))))) THEN
                        months_to_add := 0;
                    END IF;
                    
                    -- Get the day of month from start date
                    day_of_month := EXTRACT(DAY FROM start_date);
                    
                    -- Calculate next occurrence date
                    next_month_date := (date_trunc('month', from_time) + (months_to_add || ' months')::interval)::date;
                    
                    -- Handle month length issues (e.g., Feb 30)
                    DECLARE
                        days_in_month integer;
                    BEGIN
                        days_in_month := EXTRACT(DAY FROM (date_trunc('month', next_month_date) + INTERVAL '1 month - 1 day'));
                        
                        IF day_of_month > days_in_month THEN
                            day_of_month := days_in_month;
                        END IF;
                    END;
                    
                    next_start_candidate := date_trunc('month', next_month_date) + 
                                          ((day_of_month - 1) || ' days')::interval +
                                          EXTRACT(HOUR FROM pattern_start_time) * INTERVAL '1 hour' +
                                          EXTRACT(MINUTE FROM pattern_start_time) * INTERVAL '1 minute' +
                                          EXTRACT(SECOND FROM pattern_start_time) * INTERVAL '1 second';
                    next_end_candidate := next_start_candidate + duration;
                END;
                
            WHEN 'yearly' THEN
                DECLARE
                    years_since_start integer;
                    years_to_add integer;
                    next_date date;
                    month_of_year integer;
                    day_of_month integer;
                BEGIN
                    -- Calculate years since start
                    years_since_start := EXTRACT(YEAR FROM from_time) - EXTRACT(YEAR FROM start_date);
                    
                    -- Calculate next year based on interval
                    years_to_add := interval_val - (years_since_start % interval_val);
                    
                    -- If we're before the anniversary date this year and it's a valid year, don't add years
                    IF years_since_start % interval_val = 0 AND
                       (EXTRACT(MONTH FROM from_time) < EXTRACT(MONTH FROM start_date) OR
                        (EXTRACT(MONTH FROM from_time) = EXTRACT(MONTH FROM start_date) AND
                         EXTRACT(DAY FROM from_time) < EXTRACT(DAY FROM start_date)) OR
                        (EXTRACT(MONTH FROM from_time) = EXTRACT(MONTH FROM start_date) AND
                         EXTRACT(DAY FROM from_time) = EXTRACT(DAY FROM start_date) AND
                         (EXTRACT(HOUR FROM from_time) < EXTRACT(HOUR FROM pattern_start_time) OR
                          (EXTRACT(HOUR FROM from_time) = EXTRACT(HOUR FROM pattern_start_time) AND
                           EXTRACT(MINUTE FROM from_time) < EXTRACT(MINUTE FROM pattern_start_time))))) THEN
                        years_to_add := 0;
                    END IF;
                    
                    month_of_year := EXTRACT(MONTH FROM start_date);
                    day_of_month := EXTRACT(DAY FROM start_date);
                    
                    -- Handle February 29 in leap years
                    IF month_of_year = 2 AND day_of_month = 29 THEN
                        DECLARE
                            next_year integer;
                            is_leap boolean;
                        BEGIN
                            next_year := EXTRACT(YEAR FROM from_time) + years_to_add;
                            is_leap := (next_year % 4 = 0) AND (next_year % 100 <> 0 OR next_year % 400 = 0);
                            
                            IF NOT is_leap THEN
                                day_of_month := 28;
                            END IF;
                        END;
                    END IF;
                    
                    -- Calculate next occurrence date
                    next_start_candidate := make_date(
                        EXTRACT(YEAR FROM from_time)::integer + years_to_add,
                        month_of_year::integer,
                        day_of_month::integer
                    ) + 
                    EXTRACT(HOUR FROM pattern_start_time) * INTERVAL '1 hour' +
                    EXTRACT(MINUTE FROM pattern_start_time) * INTERVAL '1 minute' +
                    EXTRACT(SECOND FROM pattern_start_time) * INTERVAL '1 second';
                    
                    next_end_candidate := next_start_candidate + duration;
                END;
                
        ELSE
            -- Unknown recurrence type, skip this pattern
            RETURN;
    END CASE;
    
    -- Check if this occurrence is valid (before end recurrence if set)
    IF end_recurrence IS NOT NULL AND next_start_candidate > end_recurrence THEN
        RETURN;
    END IF;
    
    -- If we found a valid occurrence, store it
    IF next_start_candidate IS NOT NULL THEN
        next_start := next_start_candidate;
        next_end := next_end_candidate;
    END IF;
    
    RETURN;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_all_occurrences(
    schedule jsonb,
    range_start timestamptz,
    range_end timestamptz,
    max_occurrences integer DEFAULT 1000
)
RETURNS TABLE(occurrence_start timestamptz, occurrence_end timestamptz) AS $$
DECLARE
    curr_time timestamptz;
    next_occurrence RECORD;
    occurrence_count integer := 0;
BEGIN
    -- Start from the range start
    curr_time := range_start;
    
    -- Loop to find all occurrences
    WHILE occurrence_count < max_occurrences LOOP
        -- Get the next occurrence from current time
        SELECT * INTO next_occurrence FROM calculate_next_occurrence(schedule, curr_time);
        
        -- If no more occurrences found, exit
        IF next_occurrence.next_start IS NULL THEN
            EXIT;
        END IF;
        
        -- If occurrence is beyond our end range, exit
        IF next_occurrence.next_start > range_end THEN
            EXIT;
        END IF;
        
        -- Return this occurrence
        occurrence_start := next_occurrence.next_start;
        occurrence_end := next_occurrence.next_end;
        RETURN NEXT;
        occurrence_count := occurrence_count + 1;
        
        -- Move to just after this occurrence to find the next one
        curr_time := next_occurrence.next_end + INTERVAL '1 second';
    END LOOP;
    
    RETURN;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION is_schedule_in_time_range(
    schedule JSONB,
    start_date TIMESTAMP WITH TIME ZONE,
    end_date TIMESTAMP WITH TIME ZONE
)
    RETURNS BOOLEAN AS
$$
DECLARE
    schedule_start_date TIMESTAMP WITH TIME ZONE;
    schedule_end_date   TIMESTAMP WITH TIME ZONE;
    pattern_json        JSONB;
    pattern_type        TEXT;
    interval_val        INT;
    next_occurrence     TIMESTAMP WITH TIME ZONE;
    curr_date           TIMESTAMP WITH TIME ZONE; -- Renamed from current_date (reserved word)
    max_iterations      INT := 100; -- Safety limit to prevent infinite loops
    iterations          INT := 0;
BEGIN
    -- Extract schedule properties
    schedule_start_date := (schedule ->> 'start_date')::TIMESTAMP WITH TIME ZONE;
    
    IF schedule ->> 'end_date' IS NOT NULL THEN
        schedule_end_date := (schedule ->> 'end_date')::TIMESTAMP WITH TIME ZONE;
    ELSE
        schedule_end_date := NULL; -- No end date specified
    END IF;
    
    -- If schedule has no overlap with the time range, return false
    IF schedule_end_date IS NOT NULL AND schedule_end_date < start_date THEN
        RETURN FALSE; -- Schedule ends before our range starts
    END IF;
    
    IF schedule_start_date > end_date THEN
        RETURN FALSE; -- Schedule starts after our range ends
    END IF;
    
    -- If schedule_start_date is within our time range, we have an overlap
    IF schedule_start_date >= start_date AND schedule_start_date <= end_date THEN
        RETURN TRUE;
    END IF;
    
    -- Now check if any recurrence of the schedule falls within our time range
    pattern_json := schedule -> 'pattern';
    pattern_type := pattern_json ->> 'type';
    interval_val := (pattern_json ->> 'interval')::INT;
    
    -- Start from the schedule start date
    curr_date := schedule_start_date;
    
    -- Iterate through occurrences until we find one in our range or exhaust possibilities
    WHILE iterations < max_iterations AND (schedule_end_date IS NULL OR curr_date <= schedule_end_date) LOOP
        -- Calculate the next occurrence based on pattern type
        CASE pattern_type
            WHEN 'daily' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 day');
            WHEN 'weekly' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 week');
            WHEN 'monthly' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 month');
            WHEN 'yearly' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 year');
            ELSE
                -- Invalid pattern type
                RETURN FALSE;
        END CASE;
        
        -- Check if this occurrence is within our time range
        IF curr_date >= start_date AND curr_date <= end_date THEN
            -- Further validate against days_of_week, days_of_month, etc.
            IF jsonb_typeof(pattern_json -> 'days_of_week') = 'array' AND
               NOT check_days_of_week(curr_date, pattern_json -> 'days_of_week') THEN
                -- Continue to next iteration if day of week doesn't match
                iterations := iterations + 1;
                CONTINUE;
            END IF;

            IF jsonb_typeof(pattern_json -> 'days_of_month') = 'array' AND
               NOT check_days_of_month(curr_date, pattern_json -> 'days_of_month') THEN
                -- Continue to next iteration if day of month doesn't match
                iterations := iterations + 1;
                CONTINUE;
            END IF;
            
            -- Add other pattern constraints as needed
            
            -- If we passed all constraints, we have an occurrence in our range
            RETURN TRUE;
        END IF;
        
        -- If we've gone past our range, no more occurrences will be in range
        IF curr_date > end_date THEN
            RETURN FALSE;
        END IF;
        
        iterations := iterations + 1;
    END LOOP;
    
    -- If we've exhausted iterations without finding an occurrence in range
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_schedule_hours(
    schedule JSONB,
    range_start TIMESTAMP WITH TIME ZONE,
    range_end TIMESTAMP WITH TIME ZONE
)
    RETURNS NUMERIC AS
$$
DECLARE
    schedule_start_date TIMESTAMP WITH TIME ZONE;
    schedule_end_date   TIMESTAMP WITH TIME ZONE;
    pattern_json        JSONB;
    pattern_type        TEXT;
    interval_val        INT;
    curr_date           TIMESTAMP WITH TIME ZONE; -- Renamed from current_date (reserved word)
    max_iterations      INT := 366; -- Max 1 year of daily occurrences to prevent infinite loops
    iterations          INT := 0;
    total_hours         NUMERIC := 0;
    days_of_week        JSONB;
    days_of_month       JSONB;
    months_of_year      JSONB;
    count_val           INT;
    occurrences         INT := 0;
    times_json          JSONB;
    duration_hours      NUMERIC;
    time_str            TEXT;
    time_parts          TEXT[];
    duration_part       TEXT;
    hours               INT;
    minutes             INT;
BEGIN
    -- Extract schedule properties
    schedule_start_date := (schedule ->> 'start_date')::TIMESTAMP WITH TIME ZONE;
    
    IF schedule ->> 'end_date' IS NOT NULL THEN
        schedule_end_date := (schedule ->> 'end_date')::TIMESTAMP WITH TIME ZONE;
    ELSE
        schedule_end_date := NULL; -- No end date specified, treat as unlimited
    END IF;
    
    -- If schedule has no overlap with the time range, return 0
    IF schedule_end_date IS NOT NULL AND schedule_end_date < range_start THEN
        RETURN 0; -- Schedule ends before our range starts
    END IF;
    
    IF schedule_start_date > range_end THEN
        RETURN 0; -- Schedule starts after our range ends
    END IF;
    
    -- Extract pattern details
    pattern_json := schedule -> 'pattern';
    pattern_type := pattern_json ->> 'type';
    interval_val := (pattern_json ->> 'interval')::INT;
    days_of_week := pattern_json -> 'days_of_week';
    days_of_month := pattern_json -> 'days_of_month';
    months_of_year := pattern_json -> 'months_of_year';
    times_json := pattern_json -> 'times';
    
    -- Calculate duration hours from the times in the pattern if available
    BEGIN
        IF times_json IS NOT NULL AND jsonb_array_length(times_json) > 0 THEN
            -- Extract time durations from the pattern
            -- Format is typically "HH:MM/PTHM" where H is hours and M is minutes
            -- For simplicity, we'll use the first time entry to determine duration
            
            -- Variables for time parsing
            time_str := times_json->0;
            time_parts := string_to_array(time_str, '/');
            
            IF array_length(time_parts, 1) >= 2 THEN
                duration_part := time_parts[2];
                
                -- Parse PT2H30M format
                -- Extract hours
                hours := 0;
                IF duration_part ~ 'PT\d+H' THEN
                    hours := (regexp_matches(duration_part, 'PT(\d+)H'))[1]::INT;
                END IF;
                
                -- Extract minutes
                minutes := 0;
                IF duration_part ~ '\d+M' THEN
                    minutes := (regexp_matches(duration_part, '(\d+)M'))[1]::INT;
                END IF;
                
                -- Calculate total hours
                duration_hours := hours + (minutes / 60.0);
            ELSE
                -- Default to 1 hour if no duration specified
                duration_hours := 1.0;
            END IF;
        ELSE
            -- Default duration if no times specified
            duration_hours := 1.0;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- If any error in parsing, default to 1 hour
            duration_hours := 1.0;
    END;
    
    -- Check for count limit
    IF pattern_json ->> 'count' IS NOT NULL THEN
        count_val := (pattern_json ->> 'count')::INT;
    ELSE
        count_val := NULL; -- No count limit
    END IF;
    
    -- Adjust start date to be within our range if needed
    IF schedule_start_date < range_start THEN
        -- Start from the beginning of our range, but we need to calculate the correct "phase"
        -- of the schedule based on its start date
        curr_date := schedule_start_date;
        
        -- Advance curr_date to the first occurrence that is >= range_start
        WHILE curr_date < range_start AND iterations < max_iterations LOOP
            CASE pattern_type
                WHEN 'daily' THEN 
                    curr_date := curr_date + (interval_val * INTERVAL '1 day');
                WHEN 'weekly' THEN 
                    curr_date := curr_date + (interval_val * INTERVAL '1 week');
                WHEN 'monthly' THEN 
                    curr_date := curr_date + (interval_val * INTERVAL '1 month');
                WHEN 'yearly' THEN 
                    curr_date := curr_date + (interval_val * INTERVAL '1 year');
                ELSE
                    -- Invalid pattern type
                    RETURN 0;
            END CASE;
            
            iterations := iterations + 1;
            occurrences := occurrences + 1;
            
            -- If we've hit the count limit, stop
            IF count_val IS NOT NULL AND occurrences >= count_val THEN
                RETURN 0; -- All occurrences were before our range
            END IF;
        END LOOP;
    ELSE
        -- Start from the schedule's start date
        curr_date := schedule_start_date;
    END IF;
    
    -- Reset iteration counter for the main loop
    iterations := 0;
    
    -- Now iterate through occurrences until we reach the end of our range
    WHILE curr_date <= range_end AND iterations < max_iterations AND 
          (schedule_end_date IS NULL OR curr_date <= schedule_end_date) AND
          (count_val IS NULL OR occurrences < count_val) LOOP
        
        -- Check if this occurrence matches pattern constraints (days of week, month, etc.)
        IF (days_of_week IS NULL OR jsonb_typeof(days_of_week) <> 'array' OR check_days_of_week(curr_date, days_of_week)) AND
           (days_of_month IS NULL OR jsonb_typeof(days_of_month) <> 'array' OR check_days_of_month(curr_date, days_of_month)) AND
           (months_of_year IS NULL OR jsonb_typeof(months_of_year) <> 'array' OR check_months_of_year(curr_date, months_of_year)) THEN
            
            -- This occurrence is valid and within our range, add its duration to the total
            total_hours := total_hours + duration_hours;
            occurrences := occurrences + 1;
        END IF;
        
        -- Move to the next occurrence
        CASE pattern_type
            WHEN 'daily' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 day');
            WHEN 'weekly' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 week');
            WHEN 'monthly' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 month');
            WHEN 'yearly' THEN 
                curr_date := curr_date + (interval_val * INTERVAL '1 year');
            ELSE
                -- Invalid pattern type
                RETURN total_hours;
        END CASE;
        
        iterations := iterations + 1;
    END LOOP;
    
    RETURN total_hours;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN
    CREATE TYPE time_record_type AS (
        start_at timestamptz,
        end_at   timestamptz
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

CREATE OR REPLACE FUNCTION calculate_time_frequency(
    input_records time_record_type[],
    time_increment INT,
    start_date timestamptz,
    end_date timestamptz
)
    RETURNS TABLE (
                      day_year     INT,
                      start_minute INT,
                      end_minute   INT,
                      frequency    INT
                  )
    LANGUAGE sql AS
$$
WITH flattened AS (
    SELECT x.start_at, x.end_at
    FROM unnest(input_records) AS x(start_at, end_at)
),
     expanded AS (
         SELECT
             start_at AS record_start,
             COALESCE(end_at, start_at + INTERVAL '1 hour') AS record_end
         FROM flattened
         WHERE start_at IS NOT NULL
           AND (end_at IS NULL OR end_at >= start_date)
           AND start_at <= end_date
     ),
     range_expanded AS (
         SELECT
             record_start,
             record_end,
             gs::date AS curr_date,
             GREATEST(record_start, start_date, gs) AS slot_start,
             LEAST(record_end, end_date, gs + INTERVAL '1 day' - INTERVAL '1 second') AS slot_end
         FROM expanded
                  CROSS JOIN LATERAL
             generate_series(
                     DATE_TRUNC('day', GREATEST(record_start, start_date)),
                     DATE_TRUNC('day', LEAST(record_end, end_date)),
                     INTERVAL '1 day'
             ) AS gs
     ),
     slot_minutes AS (
         SELECT
             (EXTRACT(YEAR FROM curr_date)::INT * 1000 + EXTRACT(DOY FROM curr_date)::INT) AS day_year,
             floor(EXTRACT(EPOCH FROM (GREATEST(slot_start, curr_date)::time - TIME '00:00')) / 60)::INT AS s_min,
             floor(EXTRACT(EPOCH FROM (LEAST(slot_end, curr_date + INTERVAL '1 day' - INTERVAL '1 second')::time - TIME '00:00')) / 60)::INT AS e_min
         FROM range_expanded
     )
SELECT
    day_year,
    (s_min / time_increment) * time_increment AS start_minute,
    ((e_min + time_increment - 1) / time_increment) * time_increment AS end_minute,
    COUNT(*) AS frequency
FROM slot_minutes
GROUP BY day_year, (s_min / time_increment) * time_increment, ((e_min + time_increment - 1) / time_increment) * time_increment
ORDER BY frequency DESC, day_year, (s_min / time_increment) * time_increment;
$$;

CREATE OR REPLACE FUNCTION get_time_periods_by_frequency(
    input_records time_record_type[],
    time_increment INT,
    start_date TIMESTAMP WITH TIME ZONE,
    end_date TIMESTAMP WITH TIME ZONE,
    sort_order TEXT DEFAULT 'DESC',
    limit_n INT DEFAULT NULL,
    min_frequency INT DEFAULT NULL,
    max_frequency INT DEFAULT NULL
)
    RETURNS TABLE (
                      day_year     INT,
                      start_minute INT,
                      end_minute   INT,
                      frequency    INT,
                      day_date     DATE,
                      start_time   TIME,
                      end_time     TIME,
                      percentile   FLOAT
                  )
    LANGUAGE plpgsql AS
$$
DECLARE
    valid_sort TEXT;
BEGIN
    IF upper(sort_order) = 'DESC' THEN
        valid_sort := 'DESC';
    ELSIF upper(sort_order) = 'ASC' THEN
        valid_sort := 'ASC';
    ELSE
        RAISE EXCEPTION 'Invalid sort_order parameter. Use "ASC" or "DESC".';
    END IF;

    RETURN QUERY
        WITH freq_distribution AS (
            SELECT * FROM calculate_time_frequency(input_records, time_increment, start_date, end_date)
        ),
             max_freq_val_tbl AS (
                 SELECT COALESCE(MAX(f.frequency), 1) AS max_freq_val FROM freq_distribution f
             )
        SELECT
            f.day_year,
            f.start_minute,
            f.end_minute,
            f.frequency,
            (DATE(MAKE_DATE(f.day_year / 1000, 1, 1)) + ((f.day_year % 1000) - 1) * INTERVAL '1 day')::DATE AS day_date,
            MAKE_TIME((f.start_minute / 60)::INT, (f.start_minute % 60)::INT, 0) AS start_time,
            CASE
                WHEN (f.end_minute / 60)::INT = 24 THEN '23:59:59'::TIME
                ELSE MAKE_TIME((f.end_minute / 60)::INT, (f.end_minute % 60)::INT, 0)
                END AS end_time,
            f.frequency::FLOAT / (SELECT max_freq_val FROM max_freq_val_tbl)::FLOAT AS percentile
        FROM freq_distribution f
        WHERE ((min_frequency IS NULL OR f.frequency >= min_frequency) AND (max_frequency IS NULL OR f.frequency <= max_frequency))
        ORDER BY
            CASE WHEN valid_sort = 'DESC' THEN f.frequency END DESC,
            CASE WHEN valid_sort = 'ASC' THEN f.frequency END ASC,
            f.day_year,
            f.start_minute
        LIMIT limit_n;
END;
$$;

CREATE OR REPLACE FUNCTION get_bookable_available_hours(
    p_bookable_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
    RETURNS TABLE
            (
                bookable_id      UUID,
                bookable_name    TEXT,
                total_hours      NUMERIC,
                used_hours       NUMERIC,
                available_hours  NUMERIC,
                utilization_rate NUMERIC
            )
AS
$$
DECLARE
    total_period_hours NUMERIC;
    v_available_hours  NUMERIC;
    v_used_hours       NUMERIC;
    timeslot_records   RECORD;
    has_timeslots      BOOLEAN := FALSE;
    v_bookable_name    TEXT;
BEGIN
    -- Get bookable name
    SELECT name
    INTO v_bookable_name
    FROM bookable
    WHERE id = p_bookable_id
      AND sa_deleted_at IS NULL;

    -- Calculate total hours in date range
    total_period_hours := EXTRACT(EPOCH FROM (p_end_date - p_start_date)) / 3600;

    -- Calculate used hours (bookings)
    SELECT COALESCE(SUM(calculate_schedule_hours(b.schedule, p_start_date, p_end_date)), 0)
    INTO v_used_hours
    FROM booking b
    WHERE b.bookable_id = p_bookable_id
      AND b.sa_deleted_at IS NULL
      AND b.canceled_at IS NULL
      AND is_schedule_in_time_range(b.schedule, p_start_date, p_end_date);

    -- First check for timeslots directly on the bookable
    FOR timeslot_records IN
        SELECT t.id, t.schedule
        FROM object_timeslot ot
                 JOIN timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
        WHERE ot.object_id = p_bookable_id
          AND ot.object_type = 'public.bookable'
          AND ot.sa_deleted_at IS NULL
        LOOP
            has_timeslots := TRUE;
            -- For each timeslot, process its schedule to determine exact availability
            -- using the is_schedule_in_time_range function
            IF is_schedule_in_time_range(timeslot_records.schedule, p_start_date, p_end_date) THEN
                -- Process schedule logic here
            END IF;
        END LOOP;

    -- If no direct timeslots, check location-level timeslots
    IF NOT has_timeslots THEN
        FOR timeslot_records IN
            SELECT t.id, t.schedule
            FROM bookable b
                     JOIN claimius.location l ON b.sa_location_id = l.id
                     JOIN object_timeslot ot
                          ON ot.object_id = l.id AND ot.object_type = 'claimius.location' AND ot.sa_deleted_at IS NULL
                     JOIN timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
            WHERE b.id = p_bookable_id
              AND b.sa_deleted_at IS NULL
            LOOP
                has_timeslots := TRUE;
                -- Process location-level timeslot schedules
                IF is_schedule_in_time_range(timeslot_records.schedule, p_start_date, p_end_date) THEN
                    -- Process schedule logic here
                END IF;
            END LOOP;
    END IF;

    -- If still no timeslots, check organization-level timeslots
    IF NOT has_timeslots THEN
        FOR timeslot_records IN
            SELECT t.id, t.schedule
            FROM bookable b
                     JOIN object_timeslot ot
                          ON ot.object_id = b.sa_owner_id AND ot.object_type = 'claimius.organization' AND ot.sa_deleted_at IS NULL
                     JOIN timeslot t ON t.id = ot.timeslot_id AND t.sa_deleted_at IS NULL
            WHERE b.id = p_bookable_id
              AND b.sa_deleted_at IS NULL
            LOOP
                has_timeslots := TRUE;
                -- Process organization-level timeslot schedules
                IF is_schedule_in_time_range(timeslot_records.schedule, p_start_date, p_end_date) THEN
                    -- Process schedule logic here
                END IF;
            END LOOP;
    END IF;

    -- Calculate final available hours
    IF has_timeslots THEN
        -- In a full implementation, we would calculate exact hours based on schedule patterns
        -- For now, we use a simplified approach
        v_available_hours := total_period_hours * 0.4; -- Assume 40% of time is available with schedules
    ELSE
        -- No timeslots means all hours are available
        v_available_hours := total_period_hours;
    END IF;

    -- Return the result as a table row
    RETURN QUERY
        SELECT p_bookable_id                               AS bookable_id,
               v_bookable_name                             AS bookable_name,
               (v_available_hours + v_used_hours)::NUMERIC AS total_hours,
               v_used_hours::NUMERIC                       AS used_hours,
               v_available_hours::NUMERIC                  AS available_hours,
               CASE
                   WHEN (v_available_hours + v_used_hours) > 0
                       THEN (v_used_hours / (v_available_hours + v_used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                                     AS utilization_rate;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_bookable_type_available_hours(
    p_user_id UUID,
    p_required_access INTEGER,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_organization_id UUID DEFAULT NULL
)
    RETURNS TABLE
            (
                bookable_type_id   UUID,
                bookable_type_name TEXT,
                total_hours        NUMERIC,
                used_hours         NUMERIC,
                available_hours    NUMERIC,
                utilization_rate   NUMERIC
            )
AS
$$
BEGIN
    RETURN QUERY
        WITH accessible_types AS (SELECT DISTINCT go.object_id AS bookable_type_id
                                  FROM claimius.get_objects(p_user_id, claimius.get_disciple_app_id(), 'bookable_type', p_required_access) go),
             org_hierarchy AS (SELECT p_organization_id AS id
                               UNION
                               SELECT organization.id
                               FROM get_organization_descendants(p_organization_id) AS organization(id)
                               WHERE p_organization_id IS NOT NULL),
             organization_filter AS (SELECT bt.id   AS type_id,
                                            bt.name AS type_name
                                     FROM bookable_type bt
                                     WHERE bt.id IN (SELECT accessible_types.bookable_type_id FROM accessible_types)
                                       AND bt.sa_deleted_at IS NULL
                                       AND (p_organization_id IS NULL OR
                                            bt.sa_owner_id IN (SELECT oh.id FROM org_hierarchy oh))),
             type_bookables AS (SELECT bt.type_id,
                                       bt.type_name,
                                       b.id AS bookable_id
                                FROM organization_filter bt
                                         JOIN bookable b ON b.type_id = bt.type_id
                                WHERE b.sa_deleted_at IS NULL
                                  AND b.id IN (SELECT go.object_id FROM claimius.get_objects(p_user_id, claimius.get_disciple_app_id(), 'bookable', p_required_access) go)),
             bookable_stats AS (SELECT tb.type_id,
                                       tb.type_name,
                                       COALESCE(SUM(
                                                        (SELECT bh.available_hours
                                                         FROM get_bookable_available_hours(tb.bookable_id, p_start_date,
                                                                                           p_end_date) bh)
                                                ), 0) AS available_hours,
                                       COALESCE(SUM(
                                                        (SELECT bh.used_hours
                                                         FROM get_bookable_available_hours(tb.bookable_id, p_start_date,
                                                                                           p_end_date) bh)
                                                ), 0) AS used_hours
                                FROM type_bookables tb
                                GROUP BY tb.type_id, tb.type_name)
        SELECT bs.type_id                           AS bookable_type_id,
               bs.type_name                         AS bookable_type_name,
               (bs.available_hours + bs.used_hours) AS total_hours,
               bs.used_hours,
               bs.available_hours,
               CASE
                   WHEN (bs.available_hours + bs.used_hours) > 0
                       THEN (bs.used_hours / (bs.available_hours + bs.used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                              AS utilization_rate
        FROM bookable_stats bs
        ORDER BY total_hours DESC;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_organization_available_hours(
    p_organization_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
    RETURNS TABLE
            (
                organization_id   UUID,
                organization_name TEXT,
                total_hours       NUMERIC,
                used_hours        NUMERIC,
                available_hours   NUMERIC,
                utilization_rate  NUMERIC
            )
AS
$$
BEGIN
    RETURN QUERY
        WITH org_hierarchy AS (SELECT o.id, o.name::TEXT AS name
                               FROM claimius.organization o
                               WHERE o.id = p_organization_id

                               UNION

                               SELECT o.id, o.name::TEXT AS name
                               FROM claimius.organization o
                                        JOIN get_organization_descendants(p_organization_id) AS descendant(id) ON o.id = descendant.id
                               WHERE o.sa_deleted_at IS NULL),
             org_bookables AS (SELECT org.id   AS organization_id,
                                      org.name AS organization_name,
                                      b.id     AS bookable_id
                               FROM org_hierarchy org
                                        JOIN bookable b ON b.sa_owner_id = org.id
                               WHERE b.sa_deleted_at IS NULL),
             bookable_stats AS (SELECT ob.organization_id,
                                       ob.organization_name,
                                       SUM((SELECT bh.available_hours
                                            FROM get_bookable_available_hours(ob.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS available_hours,
                                       SUM((SELECT bh.used_hours
                                            FROM get_bookable_available_hours(ob.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS used_hours
                                FROM org_bookables ob
                                GROUP BY ob.organization_id, ob.organization_name)
        SELECT bs.organization_id,
               bs.organization_name,
               (bs.available_hours + bs.used_hours) AS total_hours,
               bs.used_hours,
               bs.available_hours,
               CASE
                   WHEN (bs.available_hours + bs.used_hours) > 0
                       THEN (bs.used_hours / (bs.available_hours + bs.used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                              AS utilization_rate
        FROM bookable_stats bs
        ORDER BY bs.organization_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_location_available_hours(
    p_location_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ -- TODO:: This might exclude the start location so we need to go over it again when we have gotten to implemneting more of the activity queries
)
    RETURNS TABLE
            (
                location_id      UUID,
                location_name    TEXT,
                total_hours      NUMERIC,
                used_hours       NUMERIC,
                available_hours  NUMERIC,
                utilization_rate NUMERIC
            )
AS
$$
BEGIN
    RETURN QUERY
        WITH loc_hierarchy AS (SELECT l.id, l.name::TEXT AS name
                               FROM claimius.location l
                               WHERE l.id = p_location_id

                               UNION

                               SELECT l.id, l.name::TEXT AS name
                               FROM claimius.location l
                                        JOIN get_location_descendants(p_location_id) AS descendant(id) ON l.id = descendant.id
                               WHERE l.sa_deleted_at IS NULL),
             location_bookables AS (SELECT loc.id   AS location_id,
                                           loc.name AS location_name,
                                           b.id     AS bookable_id
                                    FROM loc_hierarchy loc
                                             JOIN bookable b ON b.sa_location_id = loc.id
                                    WHERE b.sa_deleted_at IS NULL),
             bookable_stats AS (SELECT lb.location_id,
                                       lb.location_name,
                                       SUM((SELECT bh.available_hours
                                            FROM get_bookable_available_hours(lb.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS available_hours,
                                       SUM((SELECT bh.used_hours
                                            FROM get_bookable_available_hours(lb.bookable_id, p_start_date,
                                                                              p_end_date) bh)) AS used_hours
                                FROM location_bookables lb
                                GROUP BY lb.location_id, lb.location_name)
        SELECT bs.location_id,
               bs.location_name,
               (bs.available_hours + bs.used_hours) AS total_hours,
               bs.used_hours,
               bs.available_hours,
               CASE
                   WHEN (bs.available_hours + bs.used_hours) > 0
                       THEN (bs.used_hours / (bs.available_hours + bs.used_hours) * 100)::NUMERIC
                   ELSE 0::NUMERIC
                   END                              AS utilization_rate
        FROM bookable_stats bs
        ORDER BY bs.location_name;
END;
$$ LANGUAGE plpgsql;
