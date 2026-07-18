nextflow.enable.dsl = 2

// Cache diagnostic: two near-identical tasks differing ONLY in the memory directive.
// taskA_static uses a STATIC memory value; taskB_dynamic uses `memory { X * task.attempt }`.
// Run this twice with the same --cache-id. On run 2, compare cacheHit:
//   - both hit  -> dynamic memory is NOT the cache blocker (caching works)
//   - only A hit -> dynamic (task.attempt) memory disqualifies caching (confirms hypothesis)
//   - neither hit -> caching is broken for another reason (permissions/config), not memory
def WF_COMMON = '687677765589.dkr.ecr.ap-southeast-1.amazonaws.com/docker-hub/ontresearch/wf-common:sha72f3517dd994984e0e2da0b97cb3f23f8540be4b'

process taskA_static {
    container "${WF_COMMON}"
    cpus 2
    memory '4 GB'
    output:
        path 'a.txt'
    script:
        """
        echo "static-memory task, deterministic output" > a.txt
        sleep 15
        """
}

process taskB_dynamic {
    container "${WF_COMMON}"
    cpus 2
    memory { 4.GB * task.attempt }
    maxRetries 1
    errorStrategy 'retry'
    output:
        path 'b.txt'
    script:
        """
        echo "dynamic-memory task, deterministic output" > b.txt
        sleep 15
        """
}

workflow {
    taskA_static()
    taskB_dynamic()
}
