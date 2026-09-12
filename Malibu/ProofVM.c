/* Malibu is licensed under CPAL-1.0.
 * Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution. */

#include "ProofVM.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum {
    OP_NOP = 0,
    OP_ADD = 1,
    OP_AND = 2,
    OP_ASR = 3,
    OP_B = 4,
    OP_CBZ = 5,
    OP_CMP = 6,
    OP_EOR = 7,
    OP_LDM = 8,
    OP_LDR = 9,
    OP_LDRB = 10,
    OP_LDRD = 11,
    OP_LSL = 12,
    OP_LSR = 13,
    OP_MOV = 14,
    OP_MOVT = 15,
    OP_MOVW = 16,
    OP_ORR = 17,
    OP_POP = 18,
    OP_PUSH = 19,
    OP_ROR = 20,
    OP_RSB = 21,
    OP_SMLABB = 22,
    OP_STM = 23,
    OP_STR = 24,
    OP_STRB = 25,
    OP_STRD = 26,
    OP_SUB = 27,
    OP_UBFX = 28,
    OP_UXTB = 29,
};

enum {
    WORK_BASE = 0x20000000u,
    STACK_BASE = 0x30000000u,
    REGION_SIZE = 0x10000u,
    RETURN_ADDRESS = WORK_BASE + 0xf000u,
    RECORD_SIZE = 108,
    OPERAND_SIZE = 12,
};

typedef struct {
    const uint8_t *program;
    uint32_t program_count;
    uint8_t *module;
    uint32_t module_base;
    uint32_t module_size;
    uint8_t *work;
    uint8_t *stack;
    uint32_t registers[16];
    uint32_t pc;
    bool negative;
    bool zero;
    bool carry;
    bool overflow;
    int error;
} ProofMachine;

static uint32_t read_u32(const uint8_t *source) {
    return (uint32_t)source[0]
        | (uint32_t)source[1] << 8
        | (uint32_t)source[2] << 16
        | (uint32_t)source[3] << 24;
}

static void write_u32(uint8_t *destination, uint32_t value) {
    destination[0] = (uint8_t)value;
    destination[1] = (uint8_t)(value >> 8);
    destination[2] = (uint8_t)(value >> 16);
    destination[3] = (uint8_t)(value >> 24);
}

static uint8_t *memory_pointer(ProofMachine *machine, uint32_t address, uint32_t size) {
    uint64_t end = (uint64_t)address + size;
    if (address >= machine->module_base && end <= (uint64_t)machine->module_base + machine->module_size) {
        return machine->module + (address - machine->module_base);
    }
    if (address >= WORK_BASE && end <= (uint64_t)WORK_BASE + REGION_SIZE) {
        return machine->work + (address - WORK_BASE);
    }
    if (address >= STACK_BASE && end <= (uint64_t)STACK_BASE + REGION_SIZE) {
        return machine->stack + (address - STACK_BASE);
    }
    machine->error = 4;
    return NULL;
}

static uint32_t memory_read(ProofMachine *machine, uint32_t address, uint32_t size) {
    uint8_t *pointer = memory_pointer(machine, address, size);
    if (pointer == NULL) return 0;
    if (size == 1) return pointer[0];
    return read_u32(pointer);
}

static void memory_write(ProofMachine *machine, uint32_t address, uint32_t value, uint32_t size) {
    uint8_t *pointer = memory_pointer(machine, address, size);
    if (pointer == NULL) return;
    if (size == 1) pointer[0] = (uint8_t)value;
    else write_u32(pointer, value);
}

static uint32_t register_read(const ProofMachine *machine, uint8_t number) {
    return number == 15 ? machine->pc + 4u : machine->registers[number];
}

static uint32_t rotate_right(uint32_t value, uint32_t amount) {
    amount &= 31u;
    return amount == 0 ? value : (value >> amount) | (value << (32u - amount));
}

static uint32_t shifted(
    ProofMachine *machine,
    uint32_t value,
    uint8_t type,
    uint32_t amount,
    bool *carry_out
) {
    *carry_out = machine->carry;
    if (type == 0 || amount == 0) return value;
    switch (type) {
        case 1: /* ASR */
            if (amount >= 32) {
                *carry_out = (value & 0x80000000u) != 0;
                return *carry_out ? UINT32_MAX : 0;
            }
            *carry_out = (value & (1u << (amount - 1u))) != 0;
            return (value >> amount) | ((value & 0x80000000u) ? (UINT32_MAX << (32u - amount)) : 0);
        case 2: /* LSL */
            if (amount == 32) {
                *carry_out = (value & 1u) != 0;
                return 0;
            }
            if (amount > 32) {
                *carry_out = false;
                return 0;
            }
            *carry_out = (value & (1u << (32u - amount))) != 0;
            return value << amount;
        case 3: /* LSR */
            if (amount == 32) {
                *carry_out = (value & 0x80000000u) != 0;
                return 0;
            }
            if (amount > 32) {
                *carry_out = false;
                return 0;
            }
            *carry_out = (value & (1u << (amount - 1u))) != 0;
            return value >> amount;
        case 4: /* ROR */
            value = rotate_right(value, amount);
            *carry_out = (value & 0x80000000u) != 0;
            return value;
        default:
            machine->error = 5;
            return 0;
    }
}

static const uint8_t *operand_at(const uint8_t *instruction, uint8_t index) {
    return instruction + 12 + (size_t)index * OPERAND_SIZE;
}

static uint32_t operand_value(ProofMachine *machine, const uint8_t *operand, bool *carry_out) {
    switch (operand[0]) {
        case 1:
            return shifted(
                machine,
                register_read(machine, operand[1]),
                operand[2],
                operand[3],
                carry_out
            );
        case 2:
            *carry_out = machine->carry;
            return read_u32(operand + 8);
        default:
            machine->error = 6;
            *carry_out = false;
            return 0;
    }
}

static uint32_t operand_address(ProofMachine *machine, const uint8_t *operand) {
    uint32_t base = register_read(machine, operand[5]);
    if (operand[5] == 15) base &= ~3u;
    if (operand[6] != 0xff) {
        bool ignored;
        uint32_t index = shifted(
            machine,
            register_read(machine, operand[6]),
            operand[2],
            operand[3],
            &ignored
        );
        index *= operand[7];
        base = operand[4] ? base - index : base + index;
    }
    return base + read_u32(operand + 8);
}

static void set_nz(ProofMachine *machine, uint32_t result) {
    machine->negative = (result & 0x80000000u) != 0;
    machine->zero = result == 0;
}

static void set_add_flags(ProofMachine *machine, uint32_t left, uint32_t right, uint32_t result) {
    set_nz(machine, result);
    machine->carry = (uint64_t)left + right > UINT32_MAX;
    machine->overflow = ((~(left ^ right) & (left ^ result)) & 0x80000000u) != 0;
}

static void set_sub_flags(ProofMachine *machine, uint32_t left, uint32_t right, uint32_t result) {
    set_nz(machine, result);
    machine->carry = left >= right;
    machine->overflow = (((left ^ right) & (left ^ result)) & 0x80000000u) != 0;
}

static bool condition_passed(const ProofMachine *machine, uint8_t condition) {
    switch (condition) {
        case 1: return machine->zero;
        case 2: return !machine->zero;
        case 3: return machine->carry;
        case 4: return !machine->carry;
        case 5: return machine->negative;
        case 6: return !machine->negative;
        case 7: return machine->overflow;
        case 8: return !machine->overflow;
        case 9: return machine->carry && !machine->zero;
        case 10: return !machine->carry || machine->zero;
        case 11: return machine->negative == machine->overflow;
        case 12: return machine->negative != machine->overflow;
        case 13: return !machine->zero && machine->negative == machine->overflow;
        case 14: return machine->zero || machine->negative != machine->overflow;
        case 15: return true;
        default: return false;
    }
}

static const uint8_t *find_instruction(const ProofMachine *machine, uint32_t address) {
    uint32_t low = 0;
    uint32_t high = machine->program_count;
    while (low < high) {
        uint32_t middle = low + (high - low) / 2u;
        const uint8_t *candidate = machine->program + (size_t)middle * RECORD_SIZE;
        uint32_t candidate_address = read_u32(candidate);
        if (candidate_address < address) low = middle + 1u;
        else high = middle;
    }
    if (low >= machine->program_count) return NULL;
    const uint8_t *candidate = machine->program + (size_t)low * RECORD_SIZE;
    return read_u32(candidate) == address ? candidate : NULL;
}

static void execute_instruction(ProofMachine *machine, const uint8_t *instruction) {
    uint8_t opcode = instruction[4];
    uint8_t size = instruction[5];
    bool update_flags = instruction[7] != 0;
    bool writeback = instruction[8] != 0;
    uint8_t operand_count = instruction[9];
    uint8_t carry_behavior = instruction[10];
    uint32_t next_pc = machine->pc + size;
    const uint8_t *first = operand_at(instruction, 0);
    const uint8_t *second = operand_at(instruction, 1);
    const uint8_t *third = operand_at(instruction, 2);
    bool carry = machine->carry;

    if (!condition_passed(machine, instruction[6])) {
        machine->pc = next_pc;
        return;
    }

    switch (opcode) {
        case OP_NOP:
            break;
        case OP_ADD:
        case OP_SUB:
        case OP_RSB:
        case OP_AND:
        case OP_EOR:
        case OP_ORR: {
            uint8_t destination = first[1];
            uint32_t left;
            uint32_t right;
            if (operand_count == 2) {
                left = register_read(machine, destination);
                right = operand_value(machine, second, &carry);
            } else {
                bool ignored;
                left = operand_value(machine, second, &ignored);
                right = operand_value(machine, third, &carry);
            }
            uint32_t result;
            if (opcode == OP_ADD) {
                result = left + right;
                if (update_flags) set_add_flags(machine, left, right, result);
            } else if (opcode == OP_SUB) {
                result = left - right;
                if (update_flags) set_sub_flags(machine, left, right, result);
            } else if (opcode == OP_RSB) {
                result = right - left;
                if (update_flags) set_sub_flags(machine, right, left, result);
            } else {
                if (opcode == OP_AND) result = left & right;
                else if (opcode == OP_EOR) result = left ^ right;
                else result = left | right;
                if (update_flags) {
                    set_nz(machine, result);
                    if (third[2] != 0 || (operand_count == 2 && second[2] != 0)) {
                        machine->carry = carry;
                    } else if (carry_behavior != 0) {
                        machine->carry = carry_behavior == 2;
                    }
                }
            }
            machine->registers[destination] = result;
            break;
        }
        case OP_ASR:
        case OP_LSL:
        case OP_LSR:
        case OP_ROR: {
            bool ignored;
            uint32_t value = operand_value(machine, second, &ignored);
            uint32_t amount = operand_value(machine, third, &ignored);
            uint8_t shift_type = opcode == OP_ASR ? 1 : opcode == OP_LSL ? 2 : opcode == OP_LSR ? 3 : 4;
            uint32_t result = shifted(machine, value, shift_type, amount, &carry);
            machine->registers[first[1]] = result;
            if (update_flags) {
                set_nz(machine, result);
                machine->carry = carry;
            }
            break;
        }
        case OP_B:
            next_pc = read_u32(first + 8) & ~1u;
            break;
        case OP_CBZ:
            if (register_read(machine, first[1]) == 0) next_pc = read_u32(second + 8) & ~1u;
            break;
        case OP_CMP: {
            bool ignored;
            uint32_t left = operand_value(machine, first, &ignored);
            uint32_t right = operand_value(machine, second, &ignored);
            set_sub_flags(machine, left, right, left - right);
            break;
        }
        case OP_LDR:
        case OP_LDRB: {
            uint32_t address = operand_address(machine, second);
            machine->registers[first[1]] = memory_read(machine, address, opcode == OP_LDRB ? 1 : 4);
            break;
        }
        case OP_LDRD: {
            uint32_t address = operand_address(machine, third);
            machine->registers[first[1]] = memory_read(machine, address, 4);
            machine->registers[second[1]] = memory_read(machine, address + 4u, 4);
            break;
        }
        case OP_STR:
        case OP_STRB: {
            uint32_t address = operand_address(machine, second);
            memory_write(machine, address, register_read(machine, first[1]), opcode == OP_STRB ? 1 : 4);
            break;
        }
        case OP_STRD: {
            uint32_t address = operand_address(machine, third);
            memory_write(machine, address, register_read(machine, first[1]), 4);
            memory_write(machine, address + 4u, register_read(machine, second[1]), 4);
            break;
        }
        case OP_LDM:
        case OP_STM: {
            uint8_t base_register = first[1];
            uint32_t address = register_read(machine, base_register);
            uint32_t values[7] = {0};
            for (uint8_t index = 1; index < operand_count; index++) {
                const uint8_t *operand = operand_at(instruction, index);
                values[index - 1] = opcode == OP_LDM
                    ? memory_read(machine, address + (uint32_t)(index - 1) * 4u, 4)
                    : register_read(machine, operand[1]);
            }
            for (uint8_t index = 1; index < operand_count; index++) {
                const uint8_t *operand = operand_at(instruction, index);
                if (opcode == OP_LDM) machine->registers[operand[1]] = values[index - 1];
                else memory_write(machine, address + (uint32_t)(index - 1) * 4u, values[index - 1], 4);
            }
            if (writeback) machine->registers[base_register] = address + (uint32_t)(operand_count - 1) * 4u;
            break;
        }
        case OP_MOV: {
            uint32_t result = operand_value(machine, second, &carry);
            machine->registers[first[1]] = result;
            if (update_flags) {
                set_nz(machine, result);
                if (second[2] != 0) machine->carry = carry;
                else if (carry_behavior != 0) machine->carry = carry_behavior == 2;
            }
            break;
        }
        case OP_MOVW:
            machine->registers[first[1]] = read_u32(second + 8) & 0xffffu;
            break;
        case OP_MOVT:
            machine->registers[first[1]] = (machine->registers[first[1]] & 0xffffu)
                | ((read_u32(second + 8) & 0xffffu) << 16);
            break;
        case OP_PUSH: {
            machine->registers[13] -= (uint32_t)operand_count * 4u;
            for (uint8_t index = 0; index < operand_count; index++) {
                const uint8_t *operand = operand_at(instruction, index);
                memory_write(
                    machine,
                    machine->registers[13] + (uint32_t)index * 4u,
                    register_read(machine, operand[1]),
                    4
                );
            }
            break;
        }
        case OP_POP: {
            uint32_t values[8] = {0};
            for (uint8_t index = 0; index < operand_count; index++) {
                values[index] = memory_read(machine, machine->registers[13] + (uint32_t)index * 4u, 4);
            }
            machine->registers[13] += (uint32_t)operand_count * 4u;
            for (uint8_t index = 0; index < operand_count; index++) {
                const uint8_t *operand = operand_at(instruction, index);
                if (operand[1] == 15) next_pc = values[index] & ~1u;
                else machine->registers[operand[1]] = values[index];
            }
            break;
        }
        case OP_SMLABB: {
            int32_t left = (int16_t)register_read(machine, second[1]);
            int32_t right = (int16_t)register_read(machine, third[1]);
            uint32_t addend = register_read(machine, operand_at(instruction, 3)[1]);
            machine->registers[first[1]] = (uint32_t)(left * right) + addend;
            break;
        }
        case OP_UBFX: {
            uint32_t source = register_read(machine, second[1]);
            uint32_t least_bit = read_u32(third + 8);
            uint32_t width = read_u32(operand_at(instruction, 3) + 8);
            uint32_t mask = width == 32 ? UINT32_MAX : (1u << width) - 1u;
            machine->registers[first[1]] = (source >> least_bit) & mask;
            break;
        }
        case OP_UXTB:
            machine->registers[first[1]] = register_read(machine, second[1]) & 0xffu;
            break;
        default:
            machine->error = 7;
            break;
    }
    machine->pc = next_pc;
}

int spectacles_proof_generate(
    const uint8_t *asset,
    size_t asset_size,
    const uint8_t client_nonce[16],
    const uint8_t peer_nonce[16],
    const uint8_t shared_secret[32],
    uint8_t output[28]
) {
    if (asset == NULL || client_nonce == NULL || peer_nonce == NULL || shared_secret == NULL || output == NULL) {
        return 1;
    }
    if (asset_size < 28 || memcmp(asset, "SPVM", 4) != 0 || read_u32(asset + 4) != 1) return 2;
    uint32_t module_base = read_u32(asset + 8);
    uint32_t module_size = read_u32(asset + 12);
    uint32_t start = read_u32(asset + 16);
    uint32_t program_count = read_u32(asset + 24);
    uint64_t expected_size = 28u + (uint64_t)module_size + (uint64_t)program_count * RECORD_SIZE;
    if (expected_size != asset_size) return 2;

    ProofMachine machine = {0};
    machine.program = asset + 28u + module_size;
    machine.program_count = program_count;
    machine.module_base = module_base;
    machine.module_size = module_size;
    machine.module = malloc(module_size);
    machine.work = calloc(1, REGION_SIZE);
    machine.stack = calloc(1, REGION_SIZE);
    if (machine.module == NULL || machine.work == NULL || machine.stack == NULL) {
        free(machine.module);
        free(machine.work);
        free(machine.stack);
        return 3;
    }
    memcpy(machine.module, asset + 28, module_size);
    machine.pc = start;
    machine.zero = true;

    uint32_t output_message = WORK_BASE + 0x1000u;
    uint32_t output_tag = WORK_BASE + 0x1100u;
    uint32_t constant_pointer = WORK_BASE + 0x1200u;
    uint32_t input_pointer = WORK_BASE + 0x1300u;
    uint32_t state_pointer = WORK_BASE + 0x1400u;
    uint32_t stack_pointer = STACK_BASE + 0xf000u;
    memcpy(machine.work + 0x1200, "Snapchat\0\0\0\0", 12);
    memcpy(machine.work + 0x1300, peer_nonce, 16);
    memcpy(machine.work + 0x1310, shared_secret, 32);
    const uint8_t suffix[12] = {5, 9, 22, 23, 'M', 's', 'g', '1', 0, 0, 0, 0};
    memcpy(machine.work + 0x1330, suffix, sizeof(suffix));
    memcpy(machine.work + 0x1400, client_nonce, 16);
    memcpy(machine.work + 0x1410, peer_nonce, 16);
    memcpy(machine.work + 0x1420, shared_secret, 32);
    write_u32(machine.stack + 0xf000, 12);
    write_u32(machine.stack + 0xf004, input_pointer);
    write_u32(machine.stack + 0xf008, 60);
    write_u32(machine.stack + 0xf00c, 0);
    machine.registers[0] = output_message;
    machine.registers[1] = output_tag;
    machine.registers[2] = state_pointer;
    machine.registers[3] = constant_pointer;
    machine.registers[13] = stack_pointer;
    machine.registers[14] = RETURN_ADDRESS | 1u;

    uint32_t steps;
    for (steps = 0; steps < 1000000u && machine.pc != RETURN_ADDRESS && machine.error == 0; steps++) {
        const uint8_t *instruction = find_instruction(&machine, machine.pc);
        if (instruction == NULL) {
            machine.error = 8;
            break;
        }
        execute_instruction(&machine, instruction);
    }
    if (steps == 1000000u && machine.error == 0) machine.error = 9;
    if (machine.error == 0) {
        memcpy(output, machine.work + 0x1000, 12);
        memcpy(output + 12, machine.work + 0x1100, 16);
    }
    int result = machine.error;
    free(machine.module);
    free(machine.work);
    free(machine.stack);
    return result;
}
